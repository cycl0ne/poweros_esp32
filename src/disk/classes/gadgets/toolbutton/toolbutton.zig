// SPDX-License-Identifier: MIT
//! toolbutton.gadget: a button with a picture and a label, as a tool bar
//! or a ribbon has them.
//!
//! It is a buttongclass that reports when let go over it
//! (`GA_RelVerify`): buttongclass does the pressing, the key and the
//! telling of the `GA_ID`, and this class draws, measures and adds the
//! rest. A push button's code is 0. A toggle (`TBKIND_TOGGLE`) turns over
//! on the press (`GA_ToggleSelect`), tells its target `TOOLBUTTON_Checked`
//! and the gadget's `GA_ID`, and its code is the new state.
//!
//! What it shows depends on its size: large, the picture twice the small
//! one with the label under it - broken at the space nearest its middle
//! when it has one, so two words stand one above the other, and room for
//! two lines whatever, so a row of large buttons is one height; medium,
//! the small picture with the label beside it; small, the picture alone.
//! The small picture is as tall as a line of the font, even, and never
//! under 16 pixels. Without a picture the label is all there is. What it
//! shows is in the middle of its box - a medium one's at the left of it,
//! since a column of them lines up there. The label's room is its own
//! width or that of `TOOLBUTTON_RoomFor`'s text, whichever is wider.
//!
//! It is drawn as `imageclass.PART_TOOL`, by a frameiclass frame of that
//! part, in the style state its press, its toggle and the pointer put it
//! in: pressed while held, checked while on, hovered under the pointer
//! (`GFLG_HOVERLOOK`, so that intuition draws it again as the pointer
//! comes and goes). The room inside the frame is measured at rest. The
//! label's `_` marks its key, underlined. Disabled, the ghost goes over
//! the whole button.
//!
//! A drop-down or a split button has a mark after its label - beside the
//! second line of a large one's, or where that line would be - and its
//! list in a `listpanel` under it while it is held or stands open, the
//! button drawn pressed. A split button is buttongclass's for a press
//! that is not on the part with the mark, which for a large one is the
//! label's lines and for any other the mark and what is right of it; a
//! line between the two shows while the button has a border. Its key is
//! that press; a drop-down's key does nothing, a list being the
//! pointer's way in. Without labels, the press on the part with the mark
//! drops nothing of its own: it marks the button dropped
//! (`TOOLBUTTON_Dropped`, drawn pressed) and tells the target, which puts
//! up what drops down and sets it back when that is gone. The size a
//! `GM_DOMAIN` answers for is the `TOOLBUTTON_Size` among its `attrs`,
//! when it has one.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const style = intuition.style;
const icon = sdk.icon;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const listpanel = gadgets.listpanel;
const tb = gadgets.toolbutton;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IconBase = sdk.interface.icon.IconBase;
const LayersBase = sdk.interface.layers.LayersBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = tb.TOOLBUTTON_CLASS,
    .version = 1,
    .revision = 2,
    .date = "28.10.2026",
    .super = classusr.BUTTONGCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    // A drop-down's list is a layer of its own on the screen.
    .opens = &.{"layers.library"},
});
comptime {
    _ = Library;
}

/// toolbutton.gadget's part of an object.
const Data = extern struct {
    size: u32 = tb.TBSIZE_MEDIUM,
    image: ?*Object = null,
    hint: ?[*:0]const u8 = null,
    /// Its frame, of the tool part.
    frame: ?*Object = null,
    /// `TOOLBUTTON_IconName`: icon.library, open while the button has an
    /// icon; the icon; and its picture at the size `held_size`, made
    /// again when the size changes.
    icons: ?*IconBase = null,
    disk_object: ?*icon.DiskObject = null,
    held: ?*const icon.IconImage = null,
    held_size: u32 = 0,
    /// Whether it was made with a size of its own (`GA_Width`,
    /// `GA_Height`), which it then keeps, if what it shows fits.
    sized: u32 = 0,
    /// `TOOLBUTTON_RoomFor`: the text whose width the label keeps at the
    /// least, the caller's.
    room_for: ?[*:0]const u8 = null,
    kind: u32 = tb.TBKIND_PUSH,
    /// A drop-down's or a split button's list, and how many labels.
    labels: ?[*]const ?[*:0]const u8 = null,
    count: u32 = 0,
    /// The list's edge, a button's as a chooser's list has, and the list
    /// while it is down.
    list_frame: ?*Object = null,
    panel: listpanel.Panel = .{},
};

fn layersOf(base: *gadgets.Base) *LayersBase {
    return @ptrCast(base.opened[0].?);
}

/// Room between the picture and the label: under a large one's, beside a
/// medium one's.
const gap_under = 2;
const gap_beside = 4;
/// How wide a drop-down's mark is, and the room before it.
const mark_width = 9;
const gap_mark = 3;

/// Whether it drops a list down.
fn dropsDown(own: *const Data) bool {
    return own.kind == tb.TBKIND_DROPDOWN or own.kind == tb.TBKIND_SPLIT;
}

fn hasPicture(own: *const Data) bool {
    return own.image != null or own.disk_object != null;
}

/// The small picture's size for a font whose lines are `line` high.
fn smallPicture(line: i32) i32 {
    return @max(16, line + (line & 1));
}

/// The picture's size at the button's size `size`; 0 when it has none.
fn pictureSize(own: *const Data, size: u32, line: i32) i32 {
    if (!hasPicture(own)) return 0;
    const small = smallPicture(line);
    return if (size == tb.TBSIZE_LARGE) 2 * small else small;
}

/// Whether the label is shown at `size`: always but on a small button
/// with a picture.
fn showsLabel(own: *const Data, size: u32, g: *const gc.Gadget) bool {
    if (g.text == null) return false;
    return size != tb.TBSIZE_SMALL or !hasPicture(own);
}

fn textLen(text: [*:0]const u8) u32 {
    return support.textLen(text);
}

/// Where a large button's label is broken: at the space nearest its
/// middle, or nowhere.
fn breakAt(text: [*:0]const u8) ?u32 {
    const len = textLen(text);
    var best: ?u32 = null;
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        if (text[i] != ' ') continue;
        const off = @abs(@as(i32, @intCast(2 * i)) - @as(i32, @intCast(len)));
        if (best == null or off < @abs(@as(i32, @intCast(2 * best.?)) - @as(i32, @intCast(len)))) best = i;
    }
    return best;
}

/// A line of the label: `from` to `to`, the `_` that marks a key left
/// out.
const Line = struct { from: u32, to: u32 };

/// Whether the label goes under the picture: a large button's, when it
/// has a picture to go under.
fn under(size: u32, picture: i32) bool {
    return size == tb.TBSIZE_LARGE and picture > 0;
}

/// The label's lines: under the picture, two when it has a space; else
/// one.
fn linesOf(text: [*:0]const u8, two: bool) [2]?Line {
    const len = textLen(text);
    if (two) if (breakAt(text)) |at| {
        return .{ .{ .from = 0, .to = at }, .{ .from = at + 1, .to = len } };
    };
    return .{ .{ .from = 0, .to = len }, null };
}

/// The index of the `_` that marks the key, if there is one.
fn underscoreAt(text: [*:0]const u8) ?u32 {
    const at = gc.labelMark(text) orelse return null;
    return at - 1;
}

/// How wide a line of the label is in the font measured with, without
/// its `_`.
fn measuredWidth(ib: *sdk.interface.intuition.IntuitionBase, m: support.Measure, text: [*:0]const u8, line: Line) i32 {
    var buffer: [128]u8 = undefined;
    const mark = underscoreAt(text);
    var n: usize = 0;
    var i = line.from;
    while (i < line.to and n < buffer.len - 1) : (i += 1) {
        if (mark != null and i == mark.?) continue;
        buffer[n] = text[i];
        n += 1;
    }
    buffer[n] = 0;
    return m.width(ib, @ptrCast(&buffer));
}

/// How big what it shows is at `size`, in the font measured with.
fn contents(base: *gadgets.Base, own: *const Data, size: u32, g: *const gc.Gadget, m: support.Measure) gc.Box {
    const ib = base.intuition_base;
    const line = m.lineHeight(base.graphics_base);
    const picture = pictureSize(own, size, line);
    const label: ?[*:0]const u8 = if (showsLabel(own, size, g)) g.text else null;
    const mark: i32 = if (dropsDown(own)) gap_mark + mark_width else 0;
    if (under(size, picture)) {
        // The mark beside the second line, or where it would be.
        const text = label orelse {
            if (mark == 0) return .{ .width = picture, .height = picture };
            return .{ .width = @max(picture, mark_width), .height = picture + gap_under + line };
        };
        const lines = linesOf(text, true);
        var widest: i32 = if (mark != 0) mark_width else 0;
        for (lines, 0..) |maybe, i| if (maybe) |l| {
            const after: i32 = if (i == 1) mark else 0;
            widest = @max(widest, measuredWidth(ib, m, text, l) + after);
        };
        if (own.room_for) |kept| widest = @max(widest, m.width(ib, kept));
        return .{ .width = @max(picture, widest), .height = picture + gap_under + 2 * line };
    }
    var label_width = if (label) |text| measuredWidth(ib, m, text, .{ .from = 0, .to = textLen(text) }) else 0;
    if (label != null) if (own.room_for) |kept| {
        label_width = @max(label_width, m.width(ib, kept));
    };
    const beside: i32 = if (picture > 0 and label != null) gap_beside else 0;
    const height = if (label != null or mark != 0) @max(picture, line) else picture;
    return .{ .width = picture + beside + label_width + mark, .height = height };
}

/// The frame's room round what it shows, at rest.
fn inset(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) gc.Box {
    const frame = own.frame orelse return .{};
    const dri = if (gi) |info| info.draw_info else g.draw_info;
    return support.frameInset(base.intuition_base, frame, dri, g.style);
}

/// The button's size at `size` for the gadget's font: its frame round
/// what it shows.
fn nominal(base: *gadgets.Base, own: *const Data, size: u32, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) gc.Box {
    const ib = base.intuition_base;
    const m = support.Measure.of(ib, g, gi);
    defer m.done(ib);
    const inner = contents(base, own, size, g, m);
    const room = inset(base, own, g, gi);
    return .{ .width = inner.width + room.width, .height = inner.height + room.height };
}

/// Made without a size of its own, the gadget is as big as it looks
/// right: after anything that changes that.
fn fit(base: *gadgets.Base, cl: *Class, o: *Object) void {
    const own = classes.instData(Data, cl, o);
    if (own.sized != 0) return;
    const size = nominal(base, own, own.size, gc.gadget(o), null);
    const tags = [_]TagItem{
        .{ .tag = gc.GA_Width, .data = @intCast(size.width) },
        .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
    _ = base.intuition_base.SendSuperMessage(cl, o, @ptrCast(&set));
}

/// The icon's picture at `size`, taken again when the size has changed.
fn iconPicture(own: *Data, size: i32) ?*const icon.IconImage {
    const icons = own.icons orelse return null;
    const object = own.disk_object orelse return null;
    const wanted: u32 = @intCast(@max(size, 1));
    if (own.held != null and own.held_size == wanted) return own.held;
    icons.ReleaseIconImage(own.held);
    own.held = null;
    const image = object.image orelse return null;
    own.held = icons.ObtainIconImage(image, wanted);
    own.held_size = wanted;
    return own.held;
}

/// Let go of the icon and the library it came from.
fn dropIcon(base: *gadgets.Base, own: *Data) void {
    const icons = own.icons orelse return;
    icons.ReleaseIconImage(own.held);
    icons.FreeDiskObject(own.disk_object);
    base.sys_base.CloseLibrary(icons.lib());
    own.icons = null;
    own.disk_object = null;
    own.held = null;
    own.held_size = 0;
}

/// `TOOLBUTTON_IconName`: the icon read, through icon.library opened for
/// it. Nothing when the library or the icon is not there.
fn takeIcon(base: *gadgets.Base, own: *Data, name: [*:0]const u8) void {
    const lib = base.sys_base.OpenLibrary(icon.ICONNAME, 0) orelse return;
    const icons: *IconBase = @ptrCast(lib);
    const object = icons.GetDiskObject(name) orelse {
        base.sys_base.CloseLibrary(lib);
        return;
    };
    own.icons = icons;
    own.disk_object = object;
}

/// The picture, `size` square at (`left`, `top`).
fn drawPicture(base: *gadgets.Base, own: *Data, g: *const gc.Gadget, rp: *graphics.RastPort, info: *classusr.GadgetInfo, left: i32, top: i32, size: i32) void {
    if (own.image) |image| {
        var draw = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = left, .y = top },
            .state = ic.IDS_NORMAL,
            .draw_info = info.draw_info,
            .dimensions = .{ .width = size, .height = size },
            .style = g.style,
        };
        _ = base.intuition_base.SendMessage(image, @ptrCast(&draw));
        return;
    }
    const picture = iconPicture(own, size) orelse return;
    if (picture.width == 0 or picture.height == 0) return;
    // As large as the size allows, its shape kept, in the middle of it.
    const pw: i32 = @intCast(picture.width);
    const ph: i32 = @intCast(picture.height);
    const w = if (pw >= ph) size else @max(1, @divTrunc(pw * size, ph));
    const h = if (ph >= pw) size else @max(1, @divTrunc(ph * size, pw));
    const at = graphics.Rect{
        .min_x = left + @divTrunc(size - w, 2),
        .min_y = top + @divTrunc(size - h, 2),
        .max_x = left + @divTrunc(size - w, 2) + w,
        .max_y = top + @divTrunc(size - h, 2) + h,
    };
    const gb = base.graphics_base;
    const format = @intFromEnum(sdk.rtg.bitmaps.PixelFormat.rgba32);
    if (pw == w and ph == h) {
        gb.BlendPixelArray(rp, picture.pixels, picture.width * 4, format, 0, 0, &at);
    } else {
        const whole = graphics.Rect{ .max_x = pw, .max_y = ph };
        gb.ScalePixelArray(rp, picture.pixels, picture.width * 4, format, &whole, &at);
    }
}

/// How wide a line of the label is drawn, without its `_`.
fn drawnWidth(gb: *GraphicsBase, rp: *graphics.RastPort, text: [*:0]const u8, line: Line) i32 {
    var width = gb.TextLength(rp, text + line.from, line.to - line.from);
    if (underscoreAt(text)) |mark| if (mark >= line.from and mark < line.to) {
        width -= gb.TextLength(rp, text + mark, 1);
    };
    return width;
}

/// A line of the label with its top at `top`, in `ink`: the `_` that marks
/// the key not drawn, the letter after it underlined.
fn drawLine(gb: *GraphicsBase, rp: *graphics.RastPort, left: i32, top: i32, text: [*:0]const u8, line: Line, ink: graphics.Pen) void {
    var baseline: u32 = 0;
    var height: u32 = 0;
    const metrics = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{},
    };
    gb.GetRPAttrs(rp, &metrics);
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = ink },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
    const y = top + @as(i32, @intCast(baseline));
    const mark = underscoreAt(text) orelse line.to;
    if (mark < line.from or mark + 1 >= line.to) {
        gb.Move(rp, left, y);
        gb.Text(rp, text + line.from, line.to - line.from);
        return;
    }
    var x = left;
    if (mark > line.from) {
        gb.Move(rp, x, y);
        gb.Text(rp, text + line.from, mark - line.from);
        x += gb.TextLength(rp, text + line.from, mark - line.from);
    }
    const letter = text + mark + 1;
    const letter_width = gb.TextLength(rp, letter, 1);
    gb.Move(rp, x, y);
    gb.Text(rp, letter, 1);
    if (mark + 2 < line.to) {
        gb.Move(rp, x + letter_width, y);
        gb.Text(rp, letter + 1, line.to - mark - 2);
    }
    // Under the letter, as intuition's own labels have it: a pixel to the
    // left and a pixel short, on the row above the bottom of the cell.
    const below: i32 = if (height > baseline + 1) @min(@as(i32, @intCast(height - baseline - 1)), 2) else 1;
    gb.Move(rp, x - 1, y + below);
    gb.Draw(rp, x + letter_width - 2, y + below);
}

/// The style states it is drawn in: pressed while a push button is held,
/// checked while a toggle is on, and hovered or focused as intuition has
/// marked it.
fn statesOf(g: *const gc.Gadget) u32 {
    var states = gc.styleStates(g.flags);
    if (g.flags & gc.GFLG_SELECTED != 0) {
        states |= if (g.activation & gc.GACT_TOGGLESELECT != 0) style.STATE_CHECKED else style.STATE_PRESSED;
    }
    return states;
}

/// Where what the button shows goes in its box: the picture, the label's
/// lines, the mark, and where a split button's two parts meet.
const Placed = struct {
    /// How tall a line of the font is.
    line: i32,
    /// The picture's square; no width when it has none.
    picture: gc.Box = .{},
    lines: [2]?struct { line: Line, left: i32, top: i32 } = .{ null, null },
    /// The mark's box, of a button that drops a list down.
    mark: ?gc.Box = null,
    /// A split button's line between its parts: across the box at this
    /// height from the box's top for a large one, down it at this
    /// distance from the box's left for any other.
    split: ?i32 = null,
    across: bool = false,

    /// Whether a point relative to the box is on the part that drops the
    /// list down: the whole of a drop-down, a split button's part with
    /// the mark.
    fn onList(p: *const Placed, own: *const Data, x: i32, y: i32) bool {
        if (own.kind == tb.TBKIND_DROPDOWN) return true;
        const at = p.split orelse return false;
        return if (p.across) y >= at else x >= at;
    }
};

fn place(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*classusr.GadgetInfo, b: gc.Box) Placed {
    const ib = base.intuition_base;
    const m = support.Measure.of(ib, g, gi);
    defer m.done(ib);
    const line = m.lineHeight(base.graphics_base);
    var out = Placed{ .line = line };
    const room = inset(base, own, g, gi);
    const inner = gc.Box{ .left = b.left + room.left, .top = b.top + room.top, .width = b.width - room.width, .height = b.height - room.height };
    const picture = pictureSize(own, own.size, line);
    const label: ?[*:0]const u8 = if (showsLabel(own, own.size, g)) g.text else null;
    const drops = dropsDown(own);

    if (under(own.size, picture)) {
        // The picture over the label, the two in the middle; the mark
        // beside the second line, or where it would be.
        const rows: i32 = if (label != null) 2 else if (drops) 1 else 0;
        const height = picture + (if (rows > 0) gap_under + rows * line else 0);
        const top = inner.top + @divTrunc(inner.height - height, 2);
        out.picture = .{ .left = inner.left + @divTrunc(inner.width - picture, 2), .top = top, .width = picture, .height = picture };
        const text_top = top + picture + gap_under;
        if (label) |text| {
            const lines = linesOf(text, true);
            // One line sits where the first of two would.
            for (lines, 0..) |maybe, i| {
                const l = maybe orelse continue;
                const width = measuredWidth(ib, m, text, l);
                const after: i32 = if (drops and i == 1) gap_mark + mark_width else 0;
                const left = inner.left + @divTrunc(inner.width - width - after, 2);
                const y = text_top + @as(i32, @intCast(i)) * line;
                out.lines[i] = .{ .line = l, .left = left, .top = y };
                if (after > 0) out.mark = .{ .left = left + width + gap_mark, .top = y, .width = mark_width, .height = line };
            }
            if (drops and lines[1] == null) out.mark = .{ .left = inner.left + @divTrunc(inner.width - mark_width, 2), .top = text_top + line, .width = mark_width, .height = line };
        } else if (drops) {
            out.mark = .{ .left = inner.left + @divTrunc(inner.width - mark_width, 2), .top = text_top, .width = mark_width, .height = line };
        }
        out.across = true;
        if (own.kind == tb.TBKIND_SPLIT) out.split = text_top - @divTrunc(gap_under, 2) - 1 - b.top;
        return out;
    }
    // The picture, the label beside it and the mark after that, in the
    // middle of the height: at the left of a medium button, in the middle
    // of any other.
    const whole = Line{ .from = 0, .to = if (label) |text| textLen(text) else 0 };
    const label_width = if (label) |text| measuredWidth(ib, m, text, whole) else 0;
    const beside: i32 = if (picture > 0 and label != null) gap_beside else 0;
    const after: i32 = if (drops) gap_mark + mark_width else 0;
    const width = picture + beside + label_width + after;
    const left = if (own.size == tb.TBSIZE_MEDIUM) inner.left else inner.left + @divTrunc(inner.width - width, 2);
    if (picture > 0) out.picture = .{ .left = left, .top = inner.top + @divTrunc(inner.height - picture, 2), .width = picture, .height = picture };
    const text_top = inner.top + @divTrunc(inner.height - line, 2);
    if (label != null) out.lines[0] = .{ .line = whole, .left = left + picture + beside, .top = text_top };
    if (drops) {
        const mark_left = left + width - mark_width;
        out.mark = .{ .left = mark_left, .top = text_top, .width = mark_width, .height = line };
        if (own.kind == tb.TBKIND_SPLIT) out.split = mark_left - @divTrunc(gap_mark + 1, 2) - b.left;
    }
    return out;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *graphics.RastPort) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const g = gc.gadget(o);
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(g, gi);
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);

    // The frame, in the state the button is in - part of the way into it
    // while its style gives the change time.
    const states = statesOf(g);
    const shown = ib.GadgetStyleState(o, info.draw_info, ic.PART_TOOL, states);
    if (own.frame) |frame| {
        var draw = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = b.left, .y = b.top },
            .state = ic.IDS_NORMAL,
            .draw_info = info.draw_info,
            .dimensions = .{ .width = b.width, .height = b.height },
            .style = g.style,
            .style_state = shown,
        };
        _ = ib.SendMessage(frame, @ptrCast(&draw));
    }
    const ink: graphics.Pen = @truncate(ib.GetStyleAttr(info.draw_info, g.style, ic.PART_TOOL, shown, style.STYLE_TextPen));

    const at = place(base, own, g, gi, b);
    if (at.picture.width > 0) drawPicture(base, own, g, rp, info, at.picture.left, at.picture.top, at.picture.width);
    if (g.text) |text| for (at.lines) |maybe| {
        const l = maybe orelse continue;
        drawLine(gb, rp, l.left, l.top, text, l.line, ink);
    };
    if (at.mark) |mark| drawMark(gb, rp, mark, ink);
    // A split button's two parts, told apart while it has a border.
    if (at.split) |split| if (states & (style.STATE_HOVERED | style.STATE_PRESSED | style.STATE_FOCUSED) != 0) {
        const room = inset(base, own, g, gi);
        support.setPen(gb, rp, support.mixPens(ink, info.draw_info.pens[sc.BACKGROUNDPEN], 8));
        if (at.across) {
            gb.DrawHLine(rp, b.left + room.left, b.top + split, b.width - room.width);
        } else {
            gb.DrawVLine(rp, b.left + split, b.top + room.top, b.height - room.height);
        }
    };
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// The mark: a triangle pointing down, in `ink`, in the middle of `box`.
fn drawMark(gb: *GraphicsBase, rp: *graphics.RastPort, box: gc.Box, ink: graphics.Pen) void {
    support.setPen(gb, rp, ink);
    const half = @divTrunc(box.width, 2);
    const rows = half + 1;
    const top = box.top + @divTrunc(box.height - rows, 2);
    var row: i32 = 0;
    while (row < rows) : (row += 1) gb.DrawHLine(rp, box.left + row, top + row, box.width - 2 * row);
}

/// The target told whether a toggle is on, and which gadget it is.
fn tell(base: *gadgets.Base, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const g = gc.gadget(o);
    const tags = [_]TagItem{
        .{ .tag = tb.TOOLBUTTON_Checked, .data = @intFromBool(g.flags & gc.GFLG_SELECTED != 0) },
        .{ .tag = gc.GA_ID, .data = g.id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

fn isToggle(g: *const gc.Gadget) bool {
    return g.activation & gc.GACT_TOGGLESELECT != 0;
}

/// The code a press ends with: a toggle's new state, a split button's
/// `TBCODE_MAIN`, 0 for a push button.
fn code(own: *const Data, g: *const gc.Gadget) i32 {
    if (own.kind == tb.TBKIND_SPLIT) return tb.TBCODE_MAIN;
    return if (isToggle(g)) @intFromBool(g.flags & gc.GFLG_SELECTED != 0) else 0;
}

/// The list dropped down under the button, the button drawn pressed while
/// it is. False when there is nothing to list or no room.
fn dropList(base: *gadgets.Base, own: *Data, o: *Object, info: *classusr.GadgetInfo) bool {
    if (!own.panel.open(base, layersOf(base), own.list_frame, o, info, own.labels, own.count, 0, listpanel.NONE)) return false;
    gc.gadget(o).flags |= gc.GFLG_SELECTED;
    support.redraw(base.intuition_base, o, info);
    return true;
}

/// The button marked dropped, drawn pressed, and its target told - with
/// the gadget's ID, so that it knows which - for it to put up what drops
/// down.
fn dropToTarget(base: *gadgets.Base, o: *Object, info: ?*classusr.GadgetInfo) void {
    const g = gc.gadget(o);
    g.flags |= gc.GFLG_SELECTED;
    support.redraw(base.intuition_base, o, info);
    const tags = [_]TagItem{
        .{ .tag = tb.TOOLBUTTON_Dropped, .data = 1 },
        .{ .tag = gc.GA_ID, .data = g.id },
        .{},
    };
    support.notify(base.intuition_base, o, info, &tags, 0);
}

/// The list taken away and the button drawn at rest; the label under the
/// pointer, `listpanel.NONE` for none.
fn liftList(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) u32 {
    const picked = own.panel.hot;
    own.panel.close(layersOf(base));
    gc.gadget(o).flags &= ~gc.GFLG_SELECTED;
    support.redraw(base.intuition_base, o, gi);
    return picked;
}

/// The class's own attributes among `tags`. True when any of them changes
/// what it shows or how big it is.
fn setAttrs(base: *gadgets.Base, o: *Object, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var changed = false;
    if (ub.FindTagItem(tb.TOOLBUTTON_Size, tags)) |item| {
        own.size = @min(@as(u32, @truncate(item.data)), tb.TBSIZE_SMALL);
        changed = true;
    }
    if (ub.FindTagItem(tb.TOOLBUTTON_Image, tags)) |item| {
        own.image = @ptrFromInt(item.data);
        changed = true;
    }
    if (ub.FindTagItem(tb.TOOLBUTTON_Hint, tags)) |item| own.hint = @ptrFromInt(item.data);
    if (ub.FindTagItem(tb.TOOLBUTTON_RoomFor, tags)) |item| {
        own.room_for = @ptrFromInt(item.data);
        changed = true;
    }
    if (ub.FindTagItem(tb.TOOLBUTTON_Checked, tags)) |item| {
        const g = gc.gadget(o);
        if (item.data != 0) g.flags |= gc.GFLG_SELECTED else g.flags &= ~gc.GFLG_SELECTED;
        changed = true;
    }
    if (ub.FindTagItem(tb.TOOLBUTTON_Dropped, tags)) |item| if (dropsDown(own) and own.count == 0) {
        const g = gc.gadget(o);
        if (item.data != 0) g.flags |= gc.GFLG_SELECTED else g.flags &= ~gc.GFLG_SELECTED;
        changed = true;
    };
    if (ub.FindTagItem(tb.TOOLBUTTON_Labels, tags)) |item| {
        const labels: ?[*]const ?[*:0]const u8 = @ptrFromInt(item.data);
        own.labels = labels;
        own.count = 0;
        if (labels) |list| while (list[own.count] != null) {
            own.count += 1;
        };
    }
    return changed;
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
            const ub = base.utility_base;
            own.kind = @min(@as(u32, @truncate(ub.GetTagData(tb.TOOLBUTTON_Kind, tb.TBKIND_PUSH, new.attr_list))), tb.TBKIND_SPLIT);
            _ = setAttrs(base, obj, own, new.attr_list);
            if (own.image == null) if (ub.FindTagItem(tb.TOOLBUTTON_IconName, new.attr_list)) |item| {
                if (item.data != 0) takeIcon(base, own, @ptrFromInt(item.data));
            };
            const frame_tags = [_]TagItem{
                .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON },
                .{ .tag = ic.IA_StylePart, .data = ic.PART_TOOL },
                .{},
            };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            const list_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            if (dropsDown(own)) own.list_frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &list_tags);
            if (own.frame == null or (dropsDown(own) and own.list_frame == null)) {
                ib.DisposeObject(own.frame);
                ib.DisposeObject(own.list_frame);
                dropIcon(base, own);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Reported when let go over it, turned over by a press when it
            // is a toggle; something to say under gadget help; drawn again
            // as the pointer comes and goes, which its look follows.
            const toggle = own.kind == tb.TBKIND_TOGGLE;
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = gc.GA_ToggleSelect, .data = @intFromBool(toggle) },
                .{ .tag = gc.GA_GadgetHelp, .data = 1 },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            gc.gadget(obj).flags |= gc.GFLG_HOVERLOOK;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            own.sized = @intFromBool(sized);
            fit(base, cl, obj);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            own.panel.close(layersOf(base));
            ib.DisposeObject(own.list_frame);
            ib.DisposeObject(own.frame);
            dropIcon(base, own);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            const own = classes.instData(Data, cl, o.?);
            if (setAttrs(base, o.?, own, set.attr_list)) changed = 1;
            // A new label or size is a new size, unless it was given one.
            const ub = base.utility_base;
            const resized = ub.FindTagItem(tb.TOOLBUTTON_Size, set.attr_list) != null or
                ub.FindTagItem(tb.TOOLBUTTON_Image, set.attr_list) != null or
                ub.FindTagItem(tb.TOOLBUTTON_RoomFor, set.attr_list) != null or
                ub.FindTagItem(gc.GA_Text, set.attr_list) != null;
            if (resized and classes.objectClass(o.?) == cl) fit(base, cl, o.?);
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const g = gc.gadget(o.?);
            switch (get.attr_id) {
                tb.TOOLBUTTON_Size => get.storage.* = own.size,
                tb.TOOLBUTTON_Image => get.storage.* = @intFromPtr(own.image),
                tb.TOOLBUTTON_Kind => get.storage.* = own.kind,
                tb.TOOLBUTTON_Labels => get.storage.* = @intFromPtr(own.labels),
                tb.TOOLBUTTON_Dropped => get.storage.* = @intFromBool(dropsDown(own) and own.count == 0 and g.flags & gc.GFLG_SELECTED != 0),
                tb.TOOLBUTTON_Hint => get.storage.* = @intFromPtr(own.hint orelse g.text),
                tb.TOOLBUTTON_Checked => get.storage.* = @intFromBool(g.flags & gc.GFLG_SELECTED != 0),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        // Its frame round what it shows, at the least and as it looks
        // right - or the size it was made with, when larger; a medium one
        // as wide as there is room at the most, since a column of them
        // lines up, every other no larger than it looks right. Asked about
        // another of its sizes, the same for that one.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const g = gc.gadget(o.?);
            const own = classes.instData(Data, cl, o.?);
            const asked: u32 = @min(@as(u32, @truncate(base.utility_base.GetTagData(tb.TOOLBUTTON_Size, own.size, ask.attrs))), tb.TBSIZE_SMALL);
            const size = nominal(base, own, asked, g, ask.gadget_info);
            const looks = if (own.sized != 0)
                gc.Box{ .width = @max(size.width, g.given_width), .height = @max(size.height, g.given_height) }
            else
                size;
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = size.width, .height = size.height },
                gc.GDOMAIN_NOMINAL => .{ .width = looks.width, .height = looks.height },
                else => .{
                    .width = if (asked == tb.TBSIZE_MEDIUM) gc.GDOMAIN_UNLIMITED else looks.width,
                    .height = looks.height,
                },
            };
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
            return if (support.inside(ht.mouse.x, ht.mouse.y, b.width, b.height)) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            render(base, cl, o.?, r.gadget_info, r.rast_port);
            return 0;
        },
        // buttongclass turns a toggle over and draws it; the target hears
        // the new state. A press on the part that drops the list down
        // drops it - or, without a list, tells the target to drop its.
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (dropsDown(own)) {
                const g = gc.gadget(o.?);
                const b = gc.boxFor(g, in.gadget_info);
                if (in.event != null and place(base, own, g, in.gadget_info, b).onList(own, in.mouse.x, in.mouse.y)) {
                    if (own.count == 0) {
                        dropToTarget(base, o.?, in.gadget_info);
                        return gc.GMR_NOREUSE;
                    }
                    // The list needs a window to drop down on.
                    const info = in.gadget_info orelse return gc.GMR_NOREUSE;
                    return if (dropList(base, own, o.?, info)) gc.GMR_MEACTIVE else gc.GMR_NOREUSE;
                }
                if (own.kind == tb.TBKIND_DROPDOWN) return gc.GMR_NOREUSE;
            }
            const result = ib.SendSuperMessage(cl, o, msg);
            if (in.event != null and isToggle(gc.gadget(o.?))) tell(base, o.?, in.gadget_info);
            return result;
        },
        // The key is a press: a toggle turns over, and the code is what a
        // press would end with. A drop-down's does nothing.
        gc.GM_KEY => {
            const own = classes.instData(Data, cl, o.?);
            if (own.kind == tb.TBKIND_DROPDOWN) return gc.GMKR_NOTHING;
            const result = ib.SendSuperMessage(cl, o, msg);
            if (result & gc.GMKR_VERIFY != 0) {
                const k: *gc.GpKey = @ptrCast(@alignCast(msg));
                const g = gc.gadget(o.?);
                k.termination.* = code(own, g);
                if (isToggle(g)) tell(base, o.?, k.gadget_info);
            }
            return result;
        },
        // Let go over it: the code. With the list down, the list has the
        // events until the pick is over, and the label taken is the code.
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.panel.isUp()) {
                const info = in.gadget_info orelse return gc.GMR_NOREUSE;
                switch (own.panel.input(base, layersOf(base), own.list_frame, o.?, info, in)) {
                    .more => return gc.GMR_MEACTIVE,
                    .over => {
                        const picked = liftList(base, own, o.?, info);
                        if (picked == listpanel.NONE) return gc.GMR_NOREUSE;
                        in.termination.* = @intCast(picked);
                        return gc.GMR_NOREUSE | gc.GMR_VERIFY;
                    },
                }
            }
            const result = ib.SendSuperMessage(cl, o, msg);
            if (result & gc.GMR_VERIFY != 0) in.termination.* = code(own, gc.gadget(o.?));
            return result;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.panel.isUp()) {
                _ = liftList(base, own, o.?, gone.gadget_info);
                return 0;
            }
            return ib.SendSuperMessage(cl, o, msg);
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
