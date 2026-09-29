// SPDX-License-Identifier: MIT
//! chooser.gadget: a button that pops up a list to pick from.
//!
//! The button is a frameiclass button frame with the label it shows in it
//! and a mark - a triangle pointing down - at its right end, drawn as a
//! cycle gadget is. What makes it a chooser is the panel.
//!
//! **The panel is a layer over the screen**, made when the press comes
//! and deleted when the pick is over, exactly as a menu's panel is: the
//! layer keeps what it covers, so nothing has to be drawn again to put
//! the screen back, and a program drawing into a window while the panel
//! is over it draws around the panel rather than under it. It is drawn in
//! the layer's own coordinates, whose corner is the panel's.
//!
//! The panel goes under the button, or over it when there is more room
//! there, and is cut to the screen. A list too long for the room shows
//! as many labels as fit and has a bar down its right side: how far down
//! the knob sits and how long it is say where in the list the panel is
//! looking, and dragging in the bar moves it. That is the only thing
//! that scrolls it - the pointer resting anywhere moves nothing, so a
//! hand held still over the list never loses the label it was over.
//!
//! **Two ways to pick.** Pressed and dragged, the label the pointer is
//! over when the button is let go is the one taken. Pressed and let go
//! over the button itself, the panel stays up and the next press takes
//! the label under it - or closes the panel, taking nothing, if it is
//! somewhere else.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const wn = intuition.windows;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const ch = gadgets.chooser;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const LayersBase = sdk.interface.layers.LayersBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = ch.CHOOSER_CLASS,
    .version = 1,
    .date = "28.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    // The panel is a layer of its own on the screen.
    .opens = &.{"layers.library"},
});
comptime {
    _ = Library;
}

/// No label: nothing under the pointer, and nothing picked.
const NONE: u32 = 0xFFFF_FFFF;

/// Room either side of a label, in the button and in the panel.
const text_margin = 6;
/// How wide the mark's box is beside the button's text.
const mark_width = 12;
/// How wide the bar down the panel's right side is, when the list is
/// longer than the panel shows.
const bar_width = 10;

/// chooser.gadget's part of an object.
pub const Data = extern struct {
    labels: ?[*]const ?[*:0]const u8 = null,
    count: u32 = 0,
    active: u32 = 0,
    /// `CHOOSER_MaxPanelLines`: 0 for as many as there are.
    max_lines: u32 = 0,
    /// The button's frame, which the panel's edge is drawn with too.
    frame: ?*Object = null,

    // --- the panel, while it is up ---
    layer: ?*layers.Layer = null,
    /// Where the panel is on the screen, and how tall a line in it is.
    panel: gc.Box = .{},
    line_height: i32 = 8,
    /// What the frame takes off the panel's sides.
    inset: gc.Box = .{},
    /// The first label shown in the panel, and how many are shown.
    first: u32 = 0,
    visible: u32 = 0,
    /// The label under the pointer, `NONE` for none.
    hot: u32 = NONE,
    /// The button has been let go of once, so the panel stays up.
    sticky: u8 = 0,
    pad: [3]u8 = @splat(0),
};

fn layersOf(base: *gadgets.Base) *LayersBase {
    return @ptrCast(base.opened[0].?);
}

/// The attributes among `tags`: whether what the button shows changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            ch.CHOOSER_Labels => {
                const labels: ?[*]const ?[*:0]const u8 = @ptrFromInt(item.data);
                own.labels = labels;
                own.count = 0;
                if (labels) |list| while (list[own.count] != null) {
                    own.count += 1;
                };
                changed = true;
            },
            ch.CHOOSER_Active => {
                own.active = @truncate(item.data);
                changed = true;
            },
            ch.CHOOSER_MaxPanelLines => own.max_lines = @truncate(item.data),
            else => {},
        }
    }
    if (own.count == 0) own.active = 0 else if (own.active >= own.count) own.active = own.count - 1;
    return changed;
}

fn labelAt(own: *const Data, which: u32) ?[*:0]const u8 {
    if (which >= own.count) return null;
    return own.labels.?[which];
}

/// The target told which label is shown.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = ch.CHOOSER_Active, .data = own.active },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

// --- the button -------------------------------------------------------------

/// The button's size for its font: its frame round the widest label and
/// the mark.
fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    var widest: i32 = 0;
    for (0..own.count) |i| widest = @max(widest, measure.width(ib, own.labels.?[i].?));
    const line = measure.lineHeight(base.graphics_base);
    measure.done(ib);
    const dri = if (gi) |info| info.draw_info else g.draw_info;
    const inset = if (own.frame) |frame| support.frameInset(ib, frame, dri) else gc.Box{ .left = 2, .top = 2, .width = 4, .height = 4 };
    const box = gc.Box{
        .width = widest + 2 * text_margin + mark_width + inset.width,
        .height = line + inset.height,
    };
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = 2 * text_margin + mark_width + inset.width, .height = box.height },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(box.width, g.given_width), .height = box.height },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = box.height },
    };
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const g = gc.gadget(o);
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(g, info);
    const pens = info.draw_info.pens;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const pressed = own.layer != null;
    if (own.frame) |frame| support.drawFrame(ib, frame, rp, b, if (pressed) ic.IDS_SELECTED else ic.IDS_NORMAL, info.draw_info);
    const inset = if (own.frame) |frame| support.frameInset(ib, frame, info.draw_info) else gc.Box{ .left = 2, .top = 2, .width = 4, .height = 4 };
    const inner = gc.Box{
        .left = b.left + inset.left,
        .top = b.top + inset.top,
        .width = b.width - inset.width,
        .height = b.height - inset.height,
    };
    const ink = if (pressed) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN];
    support.fill(gb, rp, inner, if (pressed) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
    // The mark: a triangle pointing down, in a square at the right end.
    support.setPen(gb, rp, ink);
    support.drawArrow(ib, gb, null, rp, info.draw_info, .{
        .at = .{ .left = inner.left + inner.width - mark_width, .top = inner.top, .width = mark_width, .height = inner.height },
        .vertical = true,
        .forward = true,
    });
    if (labelAt(own, own.active)) |text| {
        var count = support.textLen(text);
        const room = inner.width - mark_width - 2 * text_margin;
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
            .{ .tag = graphics.RPTAG_APen, .data = ink },
            .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
            .{},
        };
        gb.SetRPAttrs(rp, &tags);
        const top = inner.top + @divTrunc(inner.height - @as(i32, @intCast(line)), 2);
        gb.Move(rp, inner.left + text_margin, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, text, count);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

// --- the panel --------------------------------------------------------------

/// Where the gadget is on the screen: its box in the room it is measured
/// in, that room's corner in the window, and the window's on the screen.
fn screenBox(base: *gadgets.Base, o: *Object, info: *classusr.GadgetInfo) gc.Box {
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

/// How wide the bar is; 0 when every label is shown.
fn barOf(own: *const Data) i32 {
    return if (own.count > own.visible) bar_width else 0;
}

/// Where the labels are drawn, in the panel's own coordinates.
fn linesIn(own: *const Data) gc.Box {
    return .{
        .left = own.inset.left,
        .top = own.inset.top,
        .width = own.panel.width - own.inset.width - barOf(own),
        .height = @as(i32, @intCast(own.visible)) * own.line_height,
    };
}

/// Where the bar is, in the panel's own coordinates; no width when there
/// is none.
fn barIn(own: *const Data) gc.Box {
    const width = barOf(own);
    const lines = linesIn(own);
    return .{
        .left = lines.left + lines.width,
        .top = lines.top,
        .width = width,
        .height = lines.height,
    };
}

/// The label a point on the screen is over, `NONE` for none.
fn lineAt(own: *const Data, x: i32, y: i32) u32 {
    const at = linesIn(own);
    const lines = gc.Box{
        .left = own.panel.left + at.left,
        .top = own.panel.top + at.top,
        .width = at.width,
        .height = at.height,
    };
    if (!support.inside(x - lines.left, y - lines.top, lines.width, lines.height)) return NONE;
    const row: u32 = @intCast(@divTrunc(y - lines.top, own.line_height));
    const which = own.first + row;
    return if (which < own.count) which else NONE;
}

fn panelRastPort(base: *gadgets.Base, own: *const Data) ?*graphics.RastPort {
    const layer = own.layer orelse return null;
    var where: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
    layersOf(base).GetLayerAttrs(layer, &ask);
    return @ptrFromInt(where);
}

/// One label in the panel, in the layer's own coordinates: the picked one
/// on the fill pen, the rest on the background.
fn paintLine(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, dri: *intuition.DrawInfo, which: u32) void {
    const gb = base.graphics_base;
    const pens = dri.pens;
    const row: i32 = @intCast(which - own.first);
    const lines = linesIn(own);
    const at = gc.Box{
        .left = lines.left,
        .top = lines.top + row * own.line_height,
        .width = lines.width,
        .height = own.line_height,
    };
    const picked = which == own.hot;
    support.fill(gb, rp, at, if (picked) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
    const text = labelAt(own, which) orelse return;
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

/// The whole panel drawn: its edge and every label in it.
fn paintPanel(base: *gadgets.Base, own: *const Data, info: *classusr.GadgetInfo) void {
    const layer = own.layer orelse return;
    const rp = panelRastPort(base, own) orelse return;
    const lb = layersOf(base);
    lb.LockLayer(layer);
    defer lb.UnlockLayer(layer);
    if (info.draw_info.font) |font| graphics.SetFont(base.graphics_base, rp, font);
    if (own.frame) |frame| {
        support.drawFrame(base.intuition_base, frame, rp, .{ .width = own.panel.width, .height = own.panel.height }, ic.IDS_NORMAL, info.draw_info);
    }
    var which = own.first;
    while (which < own.first + own.visible and which < own.count) : (which += 1) {
        paintLine(base, own, rp, info.draw_info, which);
    }
    paintBar(base, own, rp, info.draw_info);
}

/// The bar down the panel's right side: a sunk track with a knob as long
/// a part of it as is shown, as far down it as the panel has come.
fn paintBar(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, dri: *intuition.DrawInfo) void {
    const at = barIn(own);
    if (at.width == 0 or own.count == 0) return;
    const gb = base.graphics_base;
    const pens = dri.pens;
    support.fill(gb, rp, at, support.mixPens(pens[sc.BACKGROUNDPEN], pens[sc.SHADOWPEN], 13));
    // The knob: never shorter than it can be seen and taken hold of.
    const shown: i64 = @intCast(own.visible);
    const whole: i64 = @intCast(own.count);
    var knob: i32 = @intCast(@divTrunc(shown * at.height, whole));
    knob = @max(knob, @min(@as(i32, 8), at.height));
    const travel = at.height - knob;
    const last: i64 = whole - shown;
    const down: i32 = if (last > 0) @intCast(@divTrunc(@as(i64, own.first) * travel, last)) else 0;
    const box = gc.Box{ .left = at.left + 1, .top = at.top + down, .width = at.width - 2, .height = knob };
    support.fill(gb, rp, box, pens[sc.BACKGROUNDPEN]);
    support.setPen(gb, rp, pens[sc.SHINEPEN]);
    gb.DrawHLine(rp, box.left, box.top, box.width);
    gb.DrawVLine(rp, box.left, box.top, box.height);
    support.setPen(gb, rp, pens[sc.SHADOWPEN]);
    gb.DrawHLine(rp, box.left, box.top + box.height - 1, box.width);
    gb.DrawVLine(rp, box.left + box.width - 1, box.top, box.height);
}

/// The panel moved so that what the pointer points at in the bar is the
/// middle of what is shown. True when it moved.
fn dragBar(own: *Data, y: i32) bool {
    if (own.count <= own.visible) return false;
    const at = barIn(own);
    if (at.height <= 0) return false;
    const in = @max(@min(y - (own.panel.top + at.top), at.height - 1), 0);
    const whole: i64 = @intCast(own.count);
    const shown: i64 = @intCast(own.visible);
    var first: i64 = @divTrunc(@as(i64, in) * whole, at.height) - @divTrunc(shown, 2);
    first = @max(@min(first, whole - shown), 0);
    const wanted: u32 = @intCast(first);
    if (wanted == own.first) return false;
    own.first = wanted;
    return true;
}

/// Whether a point on the screen is in the bar.
fn inBar(own: *const Data, x: i32, y: i32) bool {
    const at = barIn(own);
    if (at.width == 0) return false;
    return support.inside(x - (own.panel.left + at.left), y - (own.panel.top + at.top), at.width, at.height);
}

/// The panel opened under the button, or over it when there is more room
/// there. False when there is no room or no memory for the layer.
fn openPanel(base: *gadgets.Base, own: *Data, o: *Object, info: *classusr.GadgetInfo) bool {
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const g = gc.gadget(o);
    const measure = support.Measure.of(ib, g, info);
    var widest: i32 = 0;
    for (0..own.count) |i| widest = @max(widest, measure.width(ib, own.labels.?[i].?));
    own.line_height = @max(measure.lineHeight(gb), 1);
    measure.done(ib);
    own.inset = if (own.frame) |frame| support.frameInset(ib, frame, info.draw_info) else gc.Box{ .left = 2, .top = 2, .width = 4, .height = 4 };

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
    // Whether the bar is needed is not known until it is known how many
    // labels fit, so the room for it is kept whenever there is a list to
    // scroll at all.
    const room_for_bar: i32 = if (own.count > 1) bar_width else 0;
    const width = @min(@max(at.width, widest + 2 * text_margin + own.inset.width + room_for_bar), screen_w);
    // As many labels as there is room for, under the button or over it,
    // whichever has more.
    const below = screen_h - (at.top + at.height);
    const above = at.top;
    const under = below >= above;
    const room = (if (under) below else above) - own.inset.height;
    var lines: u32 = @intCast(@max(@divTrunc(room, own.line_height), 0));
    if (lines == 0) return false;
    lines = @min(lines, own.count);
    if (own.max_lines != 0) lines = @min(lines, own.max_lines);
    const height = @as(i32, @intCast(lines)) * own.line_height + own.inset.height;
    const left = @max(@min(at.left, screen_w - width), 0);
    const top = if (under) at.top + at.height else at.top - height;
    own.panel = .{ .left = left, .top = top, .width = width, .height = height };
    own.visible = lines;
    // The label it shows is in view, and is the one under the pointer to
    // begin with.
    own.first = if (own.active < lines) 0 else @min(own.active - lines / 2, own.count - lines);
    own.hot = own.active;

    const bounds = graphics.Rect{
        .min_x = own.panel.left,
        .min_y = own.panel.top,
        .max_x = own.panel.left + own.panel.width,
        .max_y = own.panel.top + own.panel.height,
    };
    const tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSMART },
        .{ .tag = layers.LATAG_BackFill, .data = layers.LAYERS_NOBACKFILL },
        .{},
    };
    own.layer = layersOf(base).CreateLayerTagList(@ptrFromInt(layer_info), &tags);
    if (own.layer == null) return false;
    paintPanel(base, own, info);
    return true;
}

/// The panel taken away; what it covered comes back with the layer. The
/// button is drawn again by whoever closed it, since it is no longer
/// drawn pressed.
fn closePanel(base: *gadgets.Base, own: *Data) void {
    const layer = own.layer orelse return;
    layersOf(base).DeleteLayer(layer);
    own.layer = null;
    own.sticky = 0;
    own.hot = NONE;
}

/// The label under the pointer taken note of, and the panel drawn again
/// when it changed.
fn hover(base: *gadgets.Base, own: *Data, info: *classusr.GadgetInfo, x: i32, y: i32) void {
    const which = lineAt(own, x, y);
    if (which == own.hot) return;
    own.hot = which;
    paintPanel(base, own, info);
}

/// The label under the pointer taken: the one the gadget shows from now
/// on, reported to the window and told to the target.
fn take(base: *gadgets.Base, own: *Data, o: *Object, info: *classusr.GadgetInfo, termination: *i32) usize {
    const picked = own.hot;
    closePanel(base, own);
    if (picked != NONE) own.active = picked;
    support.redraw(base.intuition_base, o, info);
    if (picked == NONE) return gc.GMR_NOREUSE;
    termination.* = @intCast(picked);
    tell(base, own, o, info);
    return gc.GMR_NOREUSE | gc.GMR_VERIFY;
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
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            _ = setAttrs(base, own, new.attr_list);
            // Reported when a label is taken; made without a size, as big
            // as it looks right.
            const ub = base.utility_base;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            const size = domain(base, own, gc.gadget(obj), null, gc.GDOMAIN_NOMINAL);
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (sized) utility.TAG_DONE else gc.GA_Width, .data = @intCast(size.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            if (own.layer) |layer| layersOf(base).DeleteLayer(layer);
            own.layer = null;
            ib.DisposeObject(own.frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, classes.instData(Data, cl, o.?), set.attr_list)) changed = 1;
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                ch.CHOOSER_Active => get.storage.* = own.active,
                ch.CHOOSER_NumLabels => get.storage.* = own.count,
                ch.CHOOSER_Labels => get.storage.* = @intFromPtr(own.labels),
                ch.CHOOSER_MaxPanelLines => get.storage.* = own.max_lines,
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const b = gc.boxFor(gc.gadget(o.?), ht.gadget_info);
            return if (support.inside(ht.mouse.x, ht.mouse.y, b.width, b.height)) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        // The key takes the next label, the one before with a Shift key
        // held, without opening the panel: the panel is the pointer's way
        // in, and a key has no pointer.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            if (own.count == 0) return gc.GMKR_DONE;
            const shift = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;
            own.active = if (k.qualifier & shift != 0)
                (if (own.active == 0) own.count - 1 else own.active - 1)
            else
                (if (own.active + 1 >= own.count) 0 else own.active + 1);
            k.termination.* = @intCast(own.active);
            support.redraw(ib, o.?, k.gadget_info);
            tell(base, own, o.?, k.gadget_info);
            return gc.GMKR_VERIFY;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const info = in.gadget_info orelse return gc.GMR_NOREUSE;
            if (in.event == null or own.count == 0) return gc.GMR_NOREUSE;
            if (!openPanel(base, own, o.?, info)) return gc.GMR_NOREUSE;
            // Pressed: the button is drawn pressed while the panel is up.
            support.redraw(ib, o.?, info);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const info = in.gadget_info orelse return gc.GMR_NOREUSE;
            if (own.layer == null) return gc.GMR_NOREUSE;
            const e = in.event orelse return gc.GMR_MEACTIVE;
            // The pointer, which comes in relative to the gadget, on the
            // screen the panel is on.
            const at = screenBox(base, o.?, info);
            const x = at.left + in.mouse.x;
            const y = at.top + in.mouse.y;
            // Time passing moves nothing: the bar is the only way the
            // panel scrolls, so a pointer resting anywhere leaves the
            // list where it is.
            if (e.class == ie.IECLASS_TIMER) return gc.GMR_MEACTIVE;
            // The bar is dragged, not picked from.
            if (inBar(own, x, y)) {
                var drawn = false;
                if (own.hot != NONE) {
                    own.hot = NONE;
                    drawn = true;
                }
                if (dragBar(own, y)) drawn = true;
                if (drawn) paintPanel(base, own, info);
                if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX and own.sticky == 0) own.sticky = 1;
                return gc.GMR_MEACTIVE;
            }
            hover(base, own, info, x, y);
            // A press while the panel stands open: the label under it, or
            // nothing and the panel closes.
            if (e.code == ie.IECODE_LBUTTON) {
                if (own.sticky == 0) return gc.GMR_MEACTIVE;
                return take(base, own, o.?, info, in.termination);
            }
            if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                // Let go over the button itself, the panel stays up.
                if (own.sticky == 0 and support.inside(in.mouse.x, in.mouse.y, at.width, at.height)) {
                    own.sticky = 1;
                    return gc.GMR_MEACTIVE;
                }
                return take(base, own, o.?, info, in.termination);
            }
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.layer != null) {
                closePanel(base, own);
                support.redraw(ib, o.?, gone.gadget_info);
            }
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
