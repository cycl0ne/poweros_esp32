// SPDX-License-Identifier: MIT
//! fuelgauge.gadget: a bar that shows how far along something is.
//!
//! A gadgetclass gadget that is never pressed - `GM_HITTEST` finds
//! nothing - and draws in `GM_RENDER`: a sunk frameiclass frame, then the
//! filled part of the bar in the fill pen from the left or from the
//! bottom, the rest in the background pen, and the level written through
//! its format over the middle of it. The frame goes first because a
//! frameiclass frame fills the ground it stands round.
//!
//! The number is drawn a character at a time, each in the fill's text pen
//! where it lies over the filled part and in the screen's text pen where
//! it does not, so that it stays readable as the bar passes under it.
//! Drawing it character by character rather than clipping the line twice
//! keeps the gauge to one pass over the RastPort and needs no region.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const fg = gadgets.fuelgauge;
const tx = gadgets.text;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = fg.GAUGE_CLASS,
    .version = 1,
    .date = "28.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// fuelgauge.gadget's part of an object.
pub const Data = extern struct {
    min: i32 = 0,
    max: i32 = 100,
    level: i32 = 0,
    /// Filled from the bottom rather than from the left.
    vertical: u8 = 0,
    /// The number shown is the hundredths, not the level.
    percent: u8 = 0,
    pad: [2]u8 = @splat(0),
    justification: u32 = tx.TEXT_JUSTIFY_CENTER,
    /// The number is shown only through a format.
    format: ?[*:0]const u8 = null,
    /// The sunk frame round the bar.
    frame: ?*Object = null,
    /// The number as text.
    written: [40]u8 = @splat(0),
};

/// How long a gauge is at the least, and as it looks right.
const least_length = 32;
const nominal_length = 100;

fn clamp(own: *Data) void {
    if (own.min > own.max) {
        const lowest = own.max;
        own.max = own.min;
        own.min = lowest;
    }
    own.level = @max(own.min, @min(own.level, own.max));
}

/// How far along it is, in hundredths; 100 when it has nowhere to go.
pub fn percentOf(own: *const Data) i32 {
    const span: i64 = @as(i64, own.max) - own.min;
    if (span <= 0) return 100;
    return @intCast(@divTrunc((@as(i64, own.level) - own.min) * 100, span));
}

/// How much of `room` is filled.
fn filledIn(own: *const Data, room: i32) i32 {
    if (room <= 0) return 0;
    const span: i64 = @as(i64, own.max) - own.min;
    if (span <= 0) return room;
    return @intCast(@divTrunc((@as(i64, own.level) - own.min) * room, span));
}

/// The attributes among `tags`: whether anything that shows changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    const ib = base.intuition_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            fg.GAUGE_Min => {
                own.min = value;
                changed = true;
            },
            fg.GAUGE_Max => {
                own.max = value;
                changed = true;
            },
            fg.GAUGE_Level => {
                own.level = value;
                changed = true;
            },
            fg.GAUGE_Format => {
                own.format = @ptrFromInt(item.data);
                changed = true;
            },
            fg.GAUGE_Percent => {
                own.percent = @intFromBool(item.data != 0);
                changed = true;
            },
            fg.GAUGE_Justification => {
                own.justification = @truncate(item.data);
                changed = true;
            },
            else => if (new) switch (item.tag) {
                fg.GAUGE_Orientation => own.vertical = @intFromBool(item.data == fg.GAUGE_VERTICAL),
                else => {},
            },
        }
    }
    clamp(own);
    if (new and own.frame == null) {
        const frame_tags = [_]TagItem{
            .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON },
            .{ .tag = ic.IA_Recessed, .data = 1 },
            .{},
        };
        own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
    }
    return changed;
}

/// What the frame takes round the bar.
fn frameRoom(base: *gadgets.Base, own: *const Data, dri: ?*intuition.DrawInfo) gc.Box {
    const frame = own.frame orelse return .{};
    return support.frameInset(base.intuition_base, frame, dri);
}

/// The bar itself: the box in from the frame.
fn barOf(base: *gadgets.Base, own: *const Data, b: gc.Box, dri: ?*intuition.DrawInfo) gc.Box {
    const room = frameRoom(base, own, dri);
    return .{
        .left = b.left + room.left,
        .top = b.top + room.top,
        .width = b.width - room.width,
        .height = b.height - room.height,
    };
}

/// The number as text; null when no format says to show one.
fn shown(base: *gadgets.Base, own: *Data) ?[*:0]const u8 {
    const format = own.format orelse return null;
    const number: i64 = if (own.percent != 0) percentOf(own) else own.level;
    return support.formatNumber(base.sys_base, format, number, &own.written);
}

/// The number over the bar, a character at a time: each in the fill's
/// text pen where its middle lies over the filled part, and in the
/// screen's text pen where it does not.
fn drawNumber(base: *gadgets.Base, own: *Data, rp: *graphics.RastPort, bar: gc.Box, filled: i32, pens: [*]const graphics.Pen) void {
    const gb = base.graphics_base;
    const text = shown(base, own) orelse return;
    const count = support.textLen(text);
    if (count == 0) return;
    const width = gb.TextLength(rp, text, count);
    var line: u32 = 0;
    var baseline: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    const left = switch (own.justification) {
        tx.TEXT_JUSTIFY_LEFT => bar.left,
        tx.TEXT_JUSTIFY_RIGHT => bar.left + bar.width - width,
        else => bar.left + @divTrunc(bar.width - width, 2),
    };
    const top = bar.top + @divTrunc(bar.height - @as(i32, @intCast(line)), 2);
    const mode = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    gb.SetRPAttrs(rp, &mode);
    // Up the way, every character is over the same part of the bar; the
    // middle of the line decides for all of them.
    const over_all = own.vertical != 0 and top + @divTrunc(@as(i32, @intCast(line)), 2) >= bar.top + bar.height - filled;
    var at = left;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const one = text + i;
        const step = gb.TextLength(rp, one, 1);
        const over = if (own.vertical != 0) over_all else at + @divTrunc(step, 2) < bar.left + filled;
        support.setPen(gb, rp, if (over) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN]);
        gb.Move(rp, at, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, one, 1);
        at += step;
    }
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const own = classes.instData(Data, cl, o);
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const b = gc.boxFor(gc.gadget(o), info);
    const pens = info.draw_info.pens;
    const bar = barOf(base, own, b, info.draw_info);
    const room = if (own.vertical != 0) bar.height else bar.width;
    const filled = filledIn(own, room);
    // The frame first: a frameiclass frame fills what it stands round, so
    // a bar drawn before it would be painted over.
    if (own.frame) |frame| support.drawFrame(ib, frame, rp, b, ic.IDS_NORMAL, info.draw_info);
    if (own.vertical != 0) {
        support.fill(gb, rp, .{ .left = bar.left, .top = bar.top, .width = bar.width, .height = bar.height - filled }, pens[sc.BACKGROUNDPEN]);
        support.fill(gb, rp, .{ .left = bar.left, .top = bar.top + bar.height - filled, .width = bar.width, .height = filled }, pens[sc.FILLPEN]);
    } else {
        support.fill(gb, rp, .{ .left = bar.left, .top = bar.top, .width = filled, .height = bar.height }, pens[sc.FILLPEN]);
        support.fill(gb, rp, .{ .left = bar.left + filled, .top = bar.top, .width = bar.width - filled, .height = bar.height }, pens[sc.BACKGROUNDPEN]);
    }
    drawNumber(base, own, rp, bar, filled, pens);
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// Its size: a line of the font thick, a little bar at the least, and as
/// long as there is room at the most.
fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    const line = measure.lineHeight(base.graphics_base);
    measure.done(ib);
    const room = frameRoom(base, own, if (gi) |info| info.draw_info else g.draw_info);
    const thickness = line + (if (own.vertical != 0) room.width else room.height);
    const ends = if (own.vertical != 0) room.height else room.width;
    const along: i32 = switch (which) {
        gc.GDOMAIN_MINIMUM => least_length + ends,
        gc.GDOMAIN_NOMINAL => @max(nominal_length + ends, if (own.vertical != 0) g.given_height else g.given_width),
        else => gc.GDOMAIN_UNLIMITED,
    };
    return if (own.vertical != 0) .{ .width = thickness, .height = along } else .{ .width = along, .height = thickness };
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
            const ub = base.utility_base;
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) == null and ub.FindTagItem(gc.GA_Height, new.attr_list) == null) {
                const size = domain(base, own, gc.gadget(obj), null, gc.GDOMAIN_NOMINAL);
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = @intCast(size.width) },
                    .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            ib.DisposeObject(own.frame);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, classes.instData(Data, cl, o.?), set.attr_list, false)) changed = 1;
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
                fg.GAUGE_Level => get.storage.* = @bitCast(@as(isize, own.level)),
                fg.GAUGE_Min => get.storage.* = @bitCast(@as(isize, own.min)),
                fg.GAUGE_Max => get.storage.* = @bitCast(@as(isize, own.max)),
                fg.GAUGE_Percent => get.storage.* = @bitCast(@as(isize, percentOf(own))),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        // Never pressed: a press goes through it to the window.
        gc.GM_HITTEST => return 0,
        gc.GM_GOACTIVE => return gc.GMR_NOREUSE,
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
