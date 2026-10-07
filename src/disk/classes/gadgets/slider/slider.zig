// SPDX-License-Identifier: MIT
//! slider.gadget: a slider that picks a whole number.
//!
//! The gadget is a button frame of frameiclass's with a borderless
//! propgclass gadget of its own inside it, and room beside the frame for
//! the level when it is shown. The propgclass gadget is in no window's
//! list: this one places it before every message it hands on and hands on
//! the input with the pointer moved into its box. Its `ICA_TARGET` is this
//! gadget, which hears where the knob is as it moves.
//!
//! The levels are spread over the prop gadget's pot: with n levels the
//! knob is a nth of the container - at least as long as the container is
//! across, so that it can be taken hold of - level i sits at pot `MAXPOT * i /
//! (n - 1)`, and a pot is the level nearest it. Up and down, the pot is
//! turned over, so the smallest level is at the bottom. When a press ends
//! - the knob let go, or a press beside it that moved it a level - the
//! knob is put exactly on its level, the level is the code of the window's
//! `IDCMP_GADGETUP`, and the target hears it. While the knob moves, every
//! level it reaches is shown and told.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const sl = gadgets.slider;
const ie = sdk.devices.inputevent;
const tx = gadgets.text;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = sl.SLIDER_CLASS,
    .version = 1,
    .revision = 1,
    .date = "03.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// slider.gadget's part of an object.
pub const Data = extern struct {
    min: i32 = 0,
    max: i32 = 15,
    level: i32 = 0,
    /// Up and down rather than across.
    vertical: u8 = 0,
    place_right: u8 = 0,
    pad: [2]u8 = @splat(0),
    max_level_len: u32 = 2,
    /// `SLIDER_MaxLevelPixels`: room for the level in pixels as well, 0
    /// for none.
    max_level_pixels: i32 = 0,
    justify: u32 = tx.TEXT_JUSTIFY_LEFT,
    /// Shown through this, when there is one.
    format: ?[*:0]const u8 = null,
    disp_func: ?*utility.Hook = null,
    /// The container and knob: a propgclass gadget of this one's own.
    inner: ?*Object = null,
    /// The button frame round it.
    frame: ?*Object = null,
    /// The level as shown.
    written: [40]u8 = @splat(0),
};

/// Between the shown level and the frame.
const display_gap = 4;
/// The prop gadget's place in the frame: in from its sides and its top
/// and bottom.
const trim_x = 4;
const trim_y = 2;
/// How long a slider is at the least, and as it looks right.
const least_length = 32;
const nominal_length = 100;

// --- levels and pots -------------------------------------------------------

fn levels(own: *const Data) u32 {
    return @intCast(@as(i64, own.max) - own.min + 1);
}

/// The knob's size for n levels: a nth of the container, but never
/// shorter along it than the container is across - a knob that can be
/// taken hold of, and that a style can round.
fn bodyFor(own: *const Data, n: u32) u32 {
    const share: u32 = if (n > 0) pg.MAXBODY / n else pg.MAXBODY;
    const inner = gc.gadget(own.inner orelse return share);
    const along: u32 = @intCast(@max(if (own.vertical != 0) inner.height else inner.width, 1));
    const across: u32 = @intCast(@max(if (own.vertical != 0) inner.width else inner.height, 0));
    const least: u32 = @intCast(@min(@as(u64, pg.MAXBODY) * across / along, pg.MAXBODY));
    return @max(share, least);
}

/// Where level `level` puts the knob.
pub fn potFor(own: *const Data, level: i32) u32 {
    const n = levels(own);
    const index: u64 = @intCast(@as(i64, level) - own.min);
    const pot: u32 = if (n > 1) @intCast(@as(u64, pg.MAXPOT) * index / (n - 1)) else 0;
    return if (own.vertical != 0) pg.MAXPOT - pot else pot;
}

/// The level nearest a pot.
pub fn levelAt(own: *const Data, pot_given: u32) i32 {
    const n = levels(own);
    if (n <= 1) return own.min;
    const pot: u64 = if (own.vertical != 0) pg.MAXPOT - @min(pot_given, pg.MAXPOT) else pot_given;
    const index = (pot * (n - 1) + pg.MAXPOT / 2) / pg.MAXPOT;
    return own.min + @as(i32, @intCast(index));
}

fn clamp(own: *Data) void {
    if (own.min > own.max) {
        const lowest = own.max;
        own.max = own.min;
        own.min = lowest;
    }
    own.level = @max(own.min, @min(own.level, own.max));
}

/// The prop gadget's knob put on the level, drawn at once in a window.
fn putKnob(base: *gadgets.Base, own: *const Data, gi: ?*classusr.GadgetInfo) void {
    const body_tag: utility.Tag = if (own.vertical != 0) pg.PGA_VertBody else pg.PGA_HorizBody;
    const pot_tag: utility.Tag = if (own.vertical != 0) pg.PGA_VertPot else pg.PGA_HorizPot;
    const tags = [_]TagItem{
        .{ .tag = body_tag, .data = bodyFor(own, levels(own)) },
        .{ .tag = pot_tag, .data = potFor(own, own.level) },
        .{},
    };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
    _ = base.intuition_base.SendMessage(own.inner.?, @ptrCast(&set));
}

/// The attributes among `tags`: whether the level or range changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            sl.SLIDER_Min => {
                own.min = value;
                changed = true;
            },
            sl.SLIDER_Max => {
                own.max = value;
                changed = true;
            },
            sl.SLIDER_Level => {
                own.level = value;
                changed = true;
            },
            else => if (new) switch (item.tag) {
                sl.SLIDER_LevelFormat => own.format = @ptrFromInt(item.data),
                sl.SLIDER_LevelPlace => own.place_right = @intFromBool(item.data == sl.SLIDER_PLACE_RIGHT),
                sl.SLIDER_MaxLevelLen => own.max_level_len = @min(@as(u32, @truncate(item.data)), own.written.len - 1),
                sl.SLIDER_MaxLevelPixels => own.max_level_pixels = @max(@as(i32, @bitCast(@as(u32, @truncate(item.data)))), 0),
                sl.SLIDER_LevelJustify => own.justify = @truncate(item.data),
                sl.SLIDER_DispFunc => own.disp_func = @ptrFromInt(item.data),
                pg.PGA_Freedom => own.vertical = @intFromBool(item.data & pg.FREEVERT != 0),
                else => {},
            },
        }
    }
    clamp(own);
    return changed;
}

// --- where things are -------------------------------------------------------

/// How wide the shown level is: room for its characters in the font, or
/// the pixels asked for where those are wider; nothing when the level is
/// not shown.
fn displayWidth(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) i32 {
    if (own.format == null) return 0;
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    var zeros: [40]u8 = @splat('0');
    zeros[own.max_level_len] = 0;
    return @max(measure.width(ib, @ptrCast(&zeros)), own.max_level_pixels);
}

/// The parts of a gadget `size` big, relative to its box: the shown level
/// and the frame, and the prop gadget inside the frame.
const Parts = struct {
    display: gc.Box,
    frame: gc.Box,
    inner: gc.Box,

    fn of(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, size: gc.Box) Parts {
        const dw = displayWidth(base, own, g, gi);
        const room = if (dw > 0) dw + display_gap else 0;
        const display = gc.Box{ .left = if (own.place_right != 0) size.width - dw else 0, .width = dw, .height = size.height };
        const frame = gc.Box{ .left = if (own.place_right != 0) 0 else room, .width = size.width - room, .height = size.height };
        return .{
            .display = display,
            .frame = frame,
            .inner = .{ .left = frame.left + trim_x, .top = trim_y, .width = frame.width - 2 * trim_x, .height = frame.height - 2 * trim_y },
        };
    }
};

fn partsOf(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Parts {
    const g = gc.gadget(o);
    const b = gc.boxFor(g, gi);
    return Parts.of(base, own, g, gi, .{ .width = b.width, .height = b.height });
}

/// The prop gadget put where it belongs; its place in the gadget's box.
fn placeInner(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) gc.Box {
    const b = gc.boxFor(gc.gadget(o), gi);
    const at = partsOf(base, own, o, gi).inner;
    support.place(base.intuition_base, own.inner.?, .{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height });
    // The knob's least size follows the room it now has; where it is
    // stays - it may be being dragged - and nothing is drawn.
    const body_tag: utility.Tag = if (own.vertical != 0) pg.PGA_VertBody else pg.PGA_HorizBody;
    const body = [_]TagItem{ .{ .tag = body_tag, .data = bodyFor(own, levels(own)) }, .{} };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &body, .gadget_info = null };
    _ = base.intuition_base.SendMessage(own.inner.?, @ptrCast(&set));
    return at;
}

// --- drawing ----------------------------------------------------------------

/// The level as shown: through the hook first when there is one.
pub fn levelText(base: *gadgets.Base, own: *Data, o: *Object) [*:0]const u8 {
    var number: i64 = own.level;
    if (own.disp_func) |hook| {
        var level = own.level;
        number = @as(i32, @truncate(@as(isize, @bitCast(base.utility_base.CallHookPkt(hook, o, @ptrCast(&level))))));
    }
    return support.formatNumber(base.sys_base, own.format.?, number, own.written[0 .. own.max_level_len + 1]);
}

fn drawDisplay(base: *gadgets.Base, own: *Data, o: *Object, rp: *graphics.RastPort, info: *classusr.GadgetInfo) void {
    if (own.format == null) return;
    const gb = base.graphics_base;
    const b = gc.boxFor(gc.gadget(o), info);
    const area = partsOf(base, own, o, info).display;
    const at = gc.Box{ .left = b.left + area.left, .top = b.top + area.top, .width = area.width, .height = area.height };
    const styled = support.pensFor(base.intuition_base, info.draw_info, gc.gadget(o).style, sdk.intuition.style.PART_MAIN, null);
    const pens: [*]const graphics.Pen = &styled;
    support.fill(gb, rp, at, pens[sc.BACKGROUNDPEN]);
    const text = levelText(base, own, o);
    const width = gb.TextLength(rp, text, support.textLen(text));
    var line: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    const left = switch (own.justify) {
        tx.TEXT_JUSTIFY_RIGHT => at.left + at.width - width,
        tx.TEXT_JUSTIFY_CENTER => at.left + @divTrunc(at.width - width, 2),
        else => at.left,
    };
    support.drawText(gb, rp, left, at.top + @divTrunc(at.height - @as(i32, @intCast(line)), 2), text, pens[sc.TEXTPEN]);
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    const saved = support.Saved.of(gb, r.rast_port);
    defer saved.restore(gb, r.rast_port);
    const b = gc.boxFor(gc.gadget(o), info);
    const parts = partsOf(base, own, o, info);
    const frame = gc.Box{ .left = b.left + parts.frame.left, .top = b.top, .width = parts.frame.width, .height = parts.frame.height };
    support.drawGadgetFrame(ib, o, own.frame.?, r.rast_port, frame, ic.IDS_NORMAL, info.draw_info, sdk.intuition.style.PART_MAIN);
    _ = placeInner(base, own, o, info);
    support.passMarks(o, own.inner.?);
    _ = ib.SendMessage(own.inner.?, @ptrCast(r));
    drawDisplay(base, own, o, r.rast_port, info);
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(gb, r.rast_port, b, info.block_pen);
}

/// The shown level drawn again, if it is in a window.
fn redrawDisplay(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const saved = support.Saved.of(base.graphics_base, rp);
    defer saved.restore(base.graphics_base, rp);
    drawDisplay(base, own, o, rp, info);
}

/// The target told the level.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const tags = [_]TagItem{
        .{ .tag = sl.SLIDER_Level, .data = @bitCast(@as(isize, own.level)) },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, flags);
}

// --- sizes ------------------------------------------------------------------

fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    const thickness = measure.lineHeight(base.graphics_base) + 2 * trim_y + 2;
    measure.done(ib);
    const dw = displayWidth(base, own, g, gi);
    const room = if (dw > 0) dw + display_gap else 0;
    if (own.vertical != 0) {
        const across = room + thickness + 2 * trim_x;
        return switch (which) {
            gc.GDOMAIN_MINIMUM => .{ .width = across, .height = least_length },
            gc.GDOMAIN_NOMINAL => .{ .width = across, .height = @max(nominal_length, g.given_height) },
            else => .{ .width = across, .height = gc.GDOMAIN_UNLIMITED },
        };
    }
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = room + least_length, .height = thickness },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(room + nominal_length, g.given_width), .height = thickness },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = thickness },
    };
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
            _ = setAttrs(base, own, new.attr_list, true);
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            const inner_tags = [_]TagItem{
                .{ .tag = pg.PGA_Freedom, .data = if (own.vertical != 0) pg.FREEVERT else pg.FREEHORIZ },
                .{ .tag = pg.PGA_Borderless, .data = 1 },
                .{ .tag = pg.PGA_NewLook, .data = 1 },
                .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(obj) },
                .{},
            };
            if (own.frame != null) own.inner = ib.NewObjectTagList(null, classusr.PROPGCLASS, &inner_tags);
            if (own.inner == null) {
                ib.DisposeObject(own.frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Its own style is the inner one's too.
            support.passStyle(ib, base.utility_base, new.attr_list, own.inner.?);
            putKnob(base, own, null);
            // Reported when let go; made without a size, as big as it
            // looks right.
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
            ib.DisposeObject(own.inner);
            ib.DisposeObject(own.frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.inner) |inner| support.passStyle(ib, base.utility_base, set.attr_list, inner);
            const ub = base.utility_base;
            // The knob moving: the level it is nearest, shown and told
            // when it changes, and told when the move is over.
            const pot_tag: utility.Tag = if (own.vertical != 0) pg.PGA_VertPot else pg.PGA_HorizPot;
            if (msg.method_id == classusr.OM_UPDATE) if (ub.FindTagItem(pot_tag, set.attr_list)) |item| {
                const update: *classusr.OpUpdate = @ptrCast(@alignCast(msg));
                const level = levelAt(own, @truncate(item.data));
                const moved = level != own.level;
                own.level = level;
                if (moved) redrawDisplay(base, own, o.?, update.gadget_info);
                if (moved or update.flags & classusr.OPUF_INTERIM == 0) tell(base, own, o.?, update.gadget_info, update.flags);
                return 0;
            };
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list, false)) {
                putKnob(base, own, null);
                changed = 1;
            }
            if (ub.FindTagItem(gc.GA_Disabled, set.attr_list)) |item| {
                const tags = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = item.data }, .{} };
                _ = ib.SetAttrsTagList(own.inner, &tags);
            }
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
                sl.SLIDER_Level => get.storage.* = @bitCast(@as(isize, own.level)),
                sl.SLIDER_Min => get.storage.* = @bitCast(@as(isize, own.min)),
                sl.SLIDER_Max => get.storage.* = @bitCast(@as(isize, own.max)),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        // The frame and what is in it; the shown level is not pressed.
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const frame = partsOf(base, own, o.?, ht.gadget_info).frame;
            return if (support.inside(ht.mouse.x - frame.left, ht.mouse.y - frame.top, frame.width, frame.height)) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        // About a thirty-second of its range per notch, the knob going the
        // way the wheel turns, as a key steps it.
        gc.GM_WHEEL => {
            const wh: *gc.GpWheel = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const notches = gc.wheelNotches(wh, own.vertical != 0);
            if (notches == 0) return 0;
            const range: i64 = @as(i64, own.max) - own.min;
            const per_notch: i64 = @max(@divTrunc(range, 32), 1);
            const was = own.level;
            own.level = @intCast(@max(@as(i64, own.min), @min(@as(i64, own.level) + per_notch * notches, own.max)));
            if (own.level != was) {
                putKnob(base, own, wh.gadget_info);
                support.redraw(ib, o.?, wh.gadget_info);
                tell(base, own, o.?, wh.gadget_info, 0);
                return gc.wheelVerify(wh, own.level);
            }
            return gc.GMWR_TAKEN;
        },
        // The key moves the knob one level on, and back with a Shift key
        // held.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            const shift = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;
            const was = own.level;
            own.level = if (k.qualifier & shift != 0) @max(own.level - 1, own.min) else @min(own.level + 1, own.max);
            k.termination.* = own.level;
            if (own.level == was) return gc.GMKR_DONE;
            putKnob(base, own, k.gadget_info);
            support.redraw(ib, o.?, k.gadget_info);
            tell(base, own, o.?, k.gadget_info, 0);
            return gc.GMKR_VERIFY;
        },
        gc.GM_GOACTIVE, gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const was = own.level;
            const at = placeInner(base, own, o.?, in.gadget_info);
            const result = support.handOnInput(ib, own.inner.?, in, at);
            if (result & gc.GMR_VERIFY != 0) {
                // A press beside the knob, done as it is pressed: one level
                // that way, however far the knob's own length took it.
                const beside = msg.method_id == gc.GM_GOACTIVE and own.level != was and (own.level - was > 1 or was - own.level > 1);
                if (beside) {
                    own.level = if (own.level > was) was + 1 else was - 1;
                    tell(base, own, o.?, in.gadget_info, 0);
                }
                // Done: the knob on its level, which is the code.
                putKnob(base, own, in.gadget_info);
                in.termination.* = own.level;
            }
            return result;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            _ = placeInner(base, own, o.?, gone.gadget_info);
            return ib.SendMessage(own.inner.?, msg);
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
