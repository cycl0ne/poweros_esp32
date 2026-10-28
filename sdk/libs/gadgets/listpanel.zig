// SPDX-License-Identifier: MIT
//! A list popped up under a gadget to pick a label from: chooser.gadget's
//! panel, and the one a tool button that drops a list down opens.
//!
//! **The panel is a layer over the screen**, made when the press comes
//! and deleted when the pick is over, exactly as a menu's panel is: the
//! layer keeps what it covers, so nothing has to be drawn again to put
//! the screen back, and a program drawing into a window while the panel
//! is over it draws around the panel rather than under it. It is drawn in
//! the layer's own coordinates, whose corner is the panel's, its edge in
//! the frame the gadget gives.
//!
//! The panel goes under the gadget when the whole list fits there, and
//! otherwise under it or over it, whichever has more room; it is cut to
//! the screen. A list too long for the room shows
//! as many labels as fit and has a bar down its right side: how far down
//! the knob sits and how long it is say where in the list the panel is
//! looking, and dragging in the bar moves it. That is the only thing
//! that scrolls it - the pointer resting anywhere moves nothing, so a
//! hand held still over the list never loses the label it was over.
//!
//! **Two ways to pick.** Pressed and dragged, the label the pointer is
//! over when the button is let go is the one taken. Pressed and let go
//! over the gadget itself, the panel stays up and the next press takes
//! the label under it - or closes the panel, taking nothing, if it is
//! somewhere else.
//!
//! The gadget opens the panel in its `GM_GOACTIVE`, hands it every event
//! of its `GM_HANDLEINPUT` (`input`) until it says the pick is over, then
//! closes it and takes `hot`. A class that uses it opens layers.library.

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const layers = @import("../layers/layers.zig");
const intuition = @import("../intuition/intuition.zig");
const ie = @import("../../devices/inputevent.zig");
const support = @import("support.zig");
const Base = @import("classlibrary.zig").Base;
const LayersBase = @import("../../interface/layers.zig").LayersBase;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const wn = intuition.windows;
const Object = classusr.Object;
const TagItem = utility.TagItem;

/// No label: nothing under the pointer, and nothing picked.
pub const NONE: u32 = 0xFFFF_FFFF;

/// Room either side of a label, in the panel - and in a chooser's button.
pub const text_margin = 6;
/// How wide the bar down the panel's right side is, when the list is
/// longer than the panel shows.
const bar_width = 10;

/// The panel, part of the gadget's own data: up while it has a layer.
pub const Panel = extern struct {
    /// The labels it lists, and how many: given when it opens.
    labels: ?[*]const ?[*:0]const u8 = null,
    count: u32 = 0,
    layer: ?*layers.Layer = null,
    /// Where the panel is on the screen, and how tall a line in it is.
    box: gc.Box = .{},
    line_height: i32 = 8,
    /// What the frame takes off the panel's sides.
    inset: gc.Box = .{},
    /// The first label shown in the panel, and how many are shown.
    first: u32 = 0,
    visible: u32 = 0,
    /// The label under the pointer, `NONE` for none: the one taken when
    /// the pick is over.
    hot: u32 = NONE,
    /// The gadget has been let go of once, so the panel stays up.
    sticky: u8 = 0,
    pad: [3]u8 = @splat(0),

    pub fn isUp(p: *const Panel) bool {
        return p.layer != null;
    }

    fn labelAt(p: *const Panel, which: u32) ?[*:0]const u8 {
        if (which >= p.count) return null;
        return p.labels.?[which];
    }

    /// How wide the bar is; 0 when every label is shown.
    fn barOf(p: *const Panel) i32 {
        return if (p.count > p.visible) bar_width else 0;
    }

    /// Where the labels are drawn, in the panel's own coordinates.
    fn linesIn(p: *const Panel) gc.Box {
        return .{
            .left = p.inset.left,
            .top = p.inset.top,
            .width = p.box.width - p.inset.width - p.barOf(),
            .height = @as(i32, @intCast(p.visible)) * p.line_height,
        };
    }

    /// Where the bar is, in the panel's own coordinates; no width when
    /// there is none.
    fn barIn(p: *const Panel) gc.Box {
        const lines = p.linesIn();
        return .{
            .left = lines.left + lines.width,
            .top = lines.top,
            .width = p.barOf(),
            .height = lines.height,
        };
    }

    /// The label a point on the screen is over, `NONE` for none.
    fn lineAt(p: *const Panel, x: i32, y: i32) u32 {
        const at = p.linesIn();
        const left = p.box.left + at.left;
        const top = p.box.top + at.top;
        if (!support.inside(x - left, y - top, at.width, at.height)) return NONE;
        const which = p.first + @as(u32, @intCast(@divTrunc(y - top, p.line_height)));
        return if (which < p.count) which else NONE;
    }

    /// Whether a point on the screen is in the bar.
    fn inBar(p: *const Panel, x: i32, y: i32) bool {
        const at = p.barIn();
        if (at.width == 0) return false;
        return support.inside(x - (p.box.left + at.left), y - (p.box.top + at.top), at.width, at.height);
    }

    /// The panel moved so that what the pointer points at in the bar is
    /// the middle of what is shown. True when it moved.
    fn dragBar(p: *Panel, y: i32) bool {
        if (p.count <= p.visible) return false;
        const at = p.barIn();
        if (at.height <= 0) return false;
        const in = @max(@min(y - (p.box.top + at.top), at.height - 1), 0);
        const whole: i64 = @intCast(p.count);
        const shown: i64 = @intCast(p.visible);
        var first: i64 = @divTrunc(@as(i64, in) * whole, at.height) - @divTrunc(shown, 2);
        first = @max(@min(first, whole - shown), 0);
        const wanted: u32 = @intCast(first);
        if (wanted == p.first) return false;
        p.first = wanted;
        return true;
    }

    fn rastPort(p: *const Panel, lb: *LayersBase) ?*graphics.RastPort {
        const layer = p.layer orelse return null;
        var where: usize = 0;
        const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
        lb.GetLayerAttrs(layer, &ask);
        return @ptrFromInt(where);
    }

    /// One label, in the layer's own coordinates: the one under the
    /// pointer on the fill pen, the rest on the background.
    fn paintLine(p: *const Panel, base: *Base, rp: *graphics.RastPort, dri: *intuition.DrawInfo, which: u32) void {
        const gb = base.graphics_base;
        const styled = support.pensFor(base.intuition_base, dri, null, intuition.style.PART_MAIN, intuition.style.PART_SELECTION);
        const pens: [*]const graphics.Pen = &styled;
        const row: i32 = @intCast(which - p.first);
        const lines = p.linesIn();
        const at = gc.Box{
            .left = lines.left,
            .top = lines.top + row * p.line_height,
            .width = lines.width,
            .height = p.line_height,
        };
        const picked = which == p.hot;
        support.fill(gb, rp, at, if (picked) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
        const text = p.labelAt(which) orelse return;
        var count = support.textLen(text);
        const room = at.width - 2 * text_margin;
        if (gb.TextLength(rp, text, count) > room) {
            var extent: graphics.TextExtent = .{};
            count = gb.TextFit(rp, text, count, &extent, null, 1, @max(room, 0), 0);
        }
        var line: u32 = 0;
        var baseline: u32 = 0;
        const ask = [_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        };
        gb.GetRPAttrs(rp, &ask);
        const tags = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = if (picked) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN] },
            .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
            .{},
        };
        gb.SetRPAttrs(rp, &tags);
        const top = at.top + @divTrunc(at.height - @as(i32, @intCast(line)), 2);
        gb.Move(rp, at.left + text_margin, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, text, count);
    }

    /// The bar down the panel's right side: a sunk track with a knob as
    /// long a part of it as is shown, as far down it as the panel has
    /// come.
    fn paintBar(p: *const Panel, base: *Base, rp: *graphics.RastPort, dri: *intuition.DrawInfo) void {
        const at = p.barIn();
        if (at.width == 0 or p.count == 0) return;
        const gb = base.graphics_base;
        const styled = support.pensFor(base.intuition_base, dri, null, intuition.style.PART_MAIN, null);
        const pens: [*]const graphics.Pen = &styled;
        support.fill(gb, rp, at, support.mixPens(pens[sc.BACKGROUNDPEN], pens[sc.SHADOWPEN], 13));
        // The knob: never shorter than it can be seen and taken hold of.
        const shown: i64 = @intCast(p.visible);
        const whole: i64 = @intCast(p.count);
        var knob: i32 = @intCast(@divTrunc(shown * at.height, whole));
        knob = @max(knob, @min(@as(i32, 8), at.height));
        const travel = at.height - knob;
        const last: i64 = whole - shown;
        const down: i32 = if (last > 0) @intCast(@divTrunc(@as(i64, p.first) * travel, last)) else 0;
        const box = gc.Box{ .left = at.left + 1, .top = at.top + down, .width = at.width - 2, .height = knob };
        support.fill(gb, rp, box, pens[sc.BACKGROUNDPEN]);
        support.setPen(gb, rp, pens[sc.SHINEPEN]);
        gb.DrawHLine(rp, box.left, box.top, box.width);
        gb.DrawVLine(rp, box.left, box.top, box.height);
        support.setPen(gb, rp, pens[sc.SHADOWPEN]);
        gb.DrawHLine(rp, box.left, box.top + box.height - 1, box.width);
        gb.DrawVLine(rp, box.left + box.width - 1, box.top, box.height);
    }

    /// The whole panel drawn: its edge and every label in it.
    fn paint(p: *const Panel, base: *Base, lb: *LayersBase, frame: ?*Object, info: *classusr.GadgetInfo) void {
        const layer = p.layer orelse return;
        const rp = p.rastPort(lb) orelse return;
        lb.LockLayer(layer);
        defer lb.UnlockLayer(layer);
        if (info.draw_info.font) |font| graphics.SetFont(base.graphics_base, rp, font);
        if (frame) |f| {
            support.drawFrame(base.intuition_base, f, rp, .{ .width = p.box.width, .height = p.box.height }, ic.IDS_NORMAL, info.draw_info, null);
        }
        var which = p.first;
        while (which < p.first + p.visible and which < p.count) : (which += 1) {
            p.paintLine(base, rp, info.draw_info, which);
        }
        p.paintBar(base, rp, info.draw_info);
    }

    /// The panel opened under the gadget `o` - over it when the list does
    /// not fit under it and there is more room over it - at least as wide
    /// as it, listing `count` of
    /// `labels` - at most `max_lines` at once, 0 for as many as fit - with
    /// `active` in view and under the pointer to begin with. False when
    /// there is no room or no memory for the layer.
    pub fn open(p: *Panel, base: *Base, lb: *LayersBase, frame: ?*Object, o: *Object, info: *classusr.GadgetInfo, labels: ?[*]const ?[*:0]const u8, count: u32, max_lines: u32, active: u32) bool {
        const ib = base.intuition_base;
        const gb = base.graphics_base;
        if (count == 0) return false;
        p.labels = labels;
        p.count = count;
        const g = gc.gadget(o);
        const measure = support.Measure.of(ib, g, info);
        var widest: i32 = 0;
        for (0..count) |i| widest = @max(widest, measure.width(ib, labels.?[i].?));
        p.line_height = @max(measure.lineHeight(gb), 1);
        measure.done(ib);
        p.inset = if (frame) |f| support.frameInset(ib, f, info.draw_info, g.style) else gc.Box{ .left = 2, .top = 2, .width = 4, .height = 4 };

        var screen_width: usize = 0;
        var screen_height: usize = 0;
        var layer_info: usize = 0;
        const ask = [_]TagItem{
            .{ .tag = sc.SA_Width, .data = @intFromPtr(&screen_width) },
            .{ .tag = sc.SA_Height, .data = @intFromPtr(&screen_height) },
            .{ .tag = sc.SA_LayerInfo, .data = @intFromPtr(&layer_info) },
            .{},
        };
        ib.GetScreenAttrs(info.screen, &ask);
        if (layer_info == 0) return false;
        const screen_w: i32 = @intCast(screen_width);
        const screen_h: i32 = @intCast(screen_height);

        const at = screenBox(base, o, info);
        // Whether the bar is needed is not known until it is known how
        // many labels fit, so the room for it is kept whenever there is a
        // list to scroll at all.
        const room_for_bar: i32 = if (count > 1) bar_width else 0;
        const width = @min(@max(at.width, widest + 2 * text_margin + p.inset.width + room_for_bar), screen_w);
        // As many labels as there is room for: under the gadget when they
        // all fit there, a list that drops down dropping down; otherwise
        // under it or over it, whichever has more.
        const below = screen_h - (at.top + at.height);
        const above = at.top;
        const wanted = if (max_lines != 0) @min(count, max_lines) else count;
        const whole = @as(i32, @intCast(wanted)) * p.line_height + p.inset.height;
        const under = below >= whole or below >= above;
        const room = (if (under) below else above) - p.inset.height;
        var lines: u32 = @intCast(@max(@divTrunc(room, p.line_height), 0));
        if (lines == 0) return false;
        lines = @min(lines, count);
        if (max_lines != 0) lines = @min(lines, max_lines);
        const height = @as(i32, @intCast(lines)) * p.line_height + p.inset.height;
        const left = @max(@min(at.left, screen_w - width), 0);
        const top = if (under) at.top + at.height else at.top - height;
        p.box = .{ .left = left, .top = top, .width = width, .height = height };
        p.visible = lines;
        p.first = if (active >= count or active < lines) 0 else @min(active - lines / 2, count - lines);
        p.hot = if (active < count) active else NONE;
        p.sticky = 0;

        const bounds = graphics.Rect{
            .min_x = p.box.left,
            .min_y = p.box.top,
            .max_x = p.box.left + p.box.width,
            .max_y = p.box.top + p.box.height,
        };
        const tags = [_]TagItem{
            .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bounds) },
            .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSMART },
            .{ .tag = layers.LATAG_BackFill, .data = layers.LAYERS_NOBACKFILL },
            .{},
        };
        p.layer = lb.CreateLayerTagList(@ptrFromInt(layer_info), &tags);
        if (p.layer == null) return false;
        p.paint(base, lb, frame, info);
        return true;
    }

    /// The panel taken away; what it covered comes back with the layer.
    /// The gadget draws itself again, since it is no longer drawn
    /// pressed.
    pub fn close(p: *Panel, lb: *LayersBase) void {
        const layer = p.layer orelse return;
        lb.DeleteLayer(layer);
        p.layer = null;
        p.sticky = 0;
    }

    /// What `input` says of an event: the panel stays up for more, or the
    /// pick is over - `hot` taken, or nothing when it is `NONE`.
    pub const Step = enum { more, over };

    /// An event the gadget has while the panel is up, `in.mouse` relative
    /// to the gadget `o`.
    pub fn input(p: *Panel, base: *Base, lb: *LayersBase, frame: ?*Object, o: *Object, info: *classusr.GadgetInfo, in: *const gc.GpInput) Step {
        if (p.layer == null) return .over;
        const e = in.event orelse return .more;
        // The pointer, which comes in relative to the gadget, on the
        // screen the panel is on.
        const at = screenBox(base, o, info);
        const x = at.left + in.mouse.x;
        const y = at.top + in.mouse.y;
        // Time passing moves nothing: the bar is the only way the panel
        // scrolls, so a pointer resting anywhere leaves the list where it
        // is.
        if (e.class == ie.IECLASS_TIMER) return .more;
        // The bar is dragged, not picked from.
        if (p.inBar(x, y)) {
            var drawn = false;
            if (p.hot != NONE) {
                p.hot = NONE;
                drawn = true;
            }
            if (p.dragBar(y)) drawn = true;
            if (drawn) p.paint(base, lb, frame, info);
            if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX and p.sticky == 0) p.sticky = 1;
            return .more;
        }
        const which = p.lineAt(x, y);
        if (which != p.hot) {
            p.hot = which;
            p.paint(base, lb, frame, info);
        }
        // A press while the panel stands open: the label under it, or
        // nothing and the panel closes.
        if (e.code == ie.IECODE_LBUTTON) return if (p.sticky == 0) .more else .over;
        if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
            // Let go over the gadget itself, the panel stays up.
            if (p.sticky == 0 and support.inside(in.mouse.x, in.mouse.y, at.width, at.height)) {
                p.sticky = 1;
                return .more;
            }
            return .over;
        }
        return .more;
    }
};

/// Where a gadget is on the screen: its box in the room it is measured
/// in, that room's corner in the window, and the window's on the screen.
pub fn screenBox(base: *Base, o: *Object, info: *classusr.GadgetInfo) gc.Box {
    const b = gc.boxFor(gc.gadget(o), info);
    var left: usize = 0;
    var top: usize = 0;
    const ask = [_]TagItem{
        .{ .tag = wn.WA_Left, .data = @intFromPtr(&left) },
        .{ .tag = wn.WA_Top, .data = @intFromPtr(&top) },
        .{},
    };
    base.intuition_base.GetWindowAttrs(info.window, &ask);
    return .{
        .left = @as(i32, @bitCast(@as(u32, @truncate(left)))) + info.domain_left + b.left,
        .top = @as(i32, @bitCast(@as(u32, @truncate(top)))) + info.domain_top + b.top,
        .width = b.width,
        .height = b.height,
    };
}
