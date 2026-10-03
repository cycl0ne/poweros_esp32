// SPDX-License-Identifier: MIT
//! chart.gadget: lines or bars of values the gadget keeps.
//!
//! **The values** are one block allocated when the gadget is made:
//! `CHART_Series` rings of `CHART_Capacity` i32s, each with where its
//! oldest value is and how many it holds. Adding to a full ring writes
//! over its oldest and moves the start on.
//!
//! **Drawing** clears the box, works out the scale (fixed, or the values'
//! least and most widened to a round step), writes the scale's numbers in
//! a column at the left and its lines across the rest, then each series:
//! a line through its values with smooth edges, or a bar for each - a
//! slot a value wide, shared by the series side by side. The plot's width
//! is shared between `CHART_Capacity` places, the newest value at the
//! right.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const exec = sdk.exec;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const style = intuition.style;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const cr = gadgets.chart;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = cr.CHART_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// One series' ring.
pub const Ring = extern struct {
    start: u32 = 0,
    count: u32 = 0,
    colour: Pen = 0,
    /// Whether `colour` was given; otherwise it is the series' own.
    coloured: u32 = 0,
};

/// chart.gadget's part of an object.
pub const Data = extern struct {
    series: u32 = 1,
    capacity: u32 = 64,
    min: i32 = 0,
    max: i32 = 100,
    auto: u32 = 0,
    kind: u32 = cr.CHART_LINES,
    lines: u32 = 4,
    current: u32 = 0,
    rings: [cr.CHART_MAX_SERIES]Ring = @splat(.{}),
    /// `series` rings of `capacity` values, one after another.
    values: ?[*]i32 = null,
};

/// The colours of the series after the first.
const series_colours = [cr.CHART_MAX_SERIES]Pen{ 0, 0xFFC8_3C3C, 0xFF3C_A050, 0xFFE0_9020 };
const nominal = gc.Box{ .width = 200, .height = 100 };

/// The `i`th value of a series, oldest first.
pub fn valueAt(own: *const Data, series: u32, i: u32) i32 {
    const ring = own.rings[series];
    return own.values.?[series * own.capacity + (ring.start + i) % own.capacity];
}

/// A value added to a series, the oldest let go when it is full.
pub fn add(own: *Data, series: u32, value: i32) void {
    const values = own.values orelse return;
    const ring = &own.rings[series];
    if (ring.count < own.capacity) {
        values[series * own.capacity + (ring.start + ring.count) % own.capacity] = value;
        ring.count += 1;
    } else {
        values[series * own.capacity + ring.start] = value;
        ring.start = (ring.start + 1) % own.capacity;
    }
}

/// A step of 1, 2 or 5 times a power of ten at least `raw`.
fn roundStep(raw: i64) i64 {
    var power: i64 = 1;
    while (power * 10 <= raw) power *= 10;
    for ([_]i64{ 1, 2, 5, 10 }) |m| if (power * m >= raw) return power * m;
    return power * 10;
}

/// The scale: fixed, or the values' range widened to round numbers.
pub fn scaleOf(own: *const Data) [2]i64 {
    if (own.auto == 0) return .{ own.min, @max(own.max, own.min + 1) };
    var low: i64 = 0x7FFF_FFFF;
    var high: i64 = -0x8000_0000;
    for (0..own.series) |s| {
        for (0..own.rings[s].count) |i| {
            const v = valueAt(own, @intCast(s), @intCast(i));
            low = @min(low, v);
            high = @max(high, v);
        }
    }
    if (low > high) return .{ own.min, @max(own.max, own.min + 1) };
    const parts: i64 = @max(own.lines, 1);
    const step = roundStep(@max(@divTrunc(high - low + parts - 1, parts), 1));
    const bottom = @divFloor(low, step) * step;
    var top = bottom + step;
    while (top < high) top += step;
    if (top == bottom) top = bottom + step;
    return .{ bottom, top };
}

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    var changed = false;
    var state = tags;
    while (base.utility_base.NextTagItem(&state)) |item| {
        const signed: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            cr.CHART_Min => own.min = signed,
            cr.CHART_Max => own.max = signed,
            cr.CHART_Auto => own.auto = @intFromBool(item.data != 0),
            cr.CHART_Kind => own.kind = if (item.data == cr.CHART_BARS) cr.CHART_BARS else cr.CHART_LINES,
            cr.CHART_Lines => own.lines = @min(@as(u32, @truncate(item.data)), 20),
            cr.CHART_Current => own.current = @min(@as(u32, @truncate(item.data)), own.series - 1),
            cr.CHART_Add => add(own, own.current, signed),
            cr.CHART_Clear => own.rings[own.current] = .{ .colour = own.rings[own.current].colour, .coloured = own.rings[own.current].coloured },
            cr.CHART_ColourRGB => {
                own.rings[own.current].colour = @truncate(item.data);
                own.rings[own.current].coloured = 1;
            },
            else => continue,
        }
        changed = true;
    }
    return changed;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const own = classes.instData(Data, cl, o);
    const g = gc.gadget(o);
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const b = gc.boxFor(g, info);
    const dri = info.draw_info;
    const ground = support.background(ib, dri, g.style, style.PART_MAIN);
    const ink: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_MAIN, style.STATE_NORMAL, style.STYLE_TextPen));
    const first: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_INDICATOR, style.STATE_NORMAL, style.STYLE_Background));
    support.fill(gb, rp, b, ground);
    if (own.values == null) return;

    var line_u: u32 = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line_u) }, .{} });
    const line: i32 = @intCast(line_u);
    const scale = scaleOf(own);
    const span = scale[1] - scale[0];

    // The numbers' column: as wide as the widest of them.
    var numbers: [21][16]u8 = undefined;
    var widest: i32 = 0;
    for (0..own.lines + 1) |i| {
        const value = scale[0] + @divTrunc(span * @as(i64, @intCast(i)), @max(own.lines, 1));
        const text = support.formatNumber(base.sys_base, "%ld", value, &numbers[i]);
        widest = @max(widest, gb.TextLength(rp, text, support.textLen(text)));
    }
    const half: i32 = @divTrunc(line, 2);
    const plot = gc.Box{
        .left = b.left + (if (own.lines > 0) widest + 4 else 0),
        .top = b.top + half,
        .width = b.width - (if (own.lines > 0) widest + 4 else 0) - 2,
        .height = b.height - 2 * half,
    };
    if (plot.width < 4 or plot.height < 4) return;
    const yOf = struct {
        fn of(p: gc.Box, low: i64, range: i64, value: i64) i32 {
            const clamped = @max(low, @min(value, low + range));
            return p.top + p.height - 1 - @as(i32, @intCast(@divTrunc((clamped - low) * (p.height - 1), range)));
        }
    }.of;

    // The scale's lines and numbers.
    const faint = support.mixPens(ink, ground, 4);
    for (0..own.lines + 1) |i| {
        if (own.lines == 0) break;
        const value = scale[0] + @divTrunc(span * @as(i64, @intCast(i)), own.lines);
        const y = yOf(plot, scale[0], span, value);
        support.setPen(gb, rp, faint);
        gb.DrawHLine(rp, plot.left, y, plot.width);
        const text: [*:0]const u8 = @ptrCast(&numbers[i]);
        const w = gb.TextLength(rp, text, support.textLen(text));
        support.drawText(gb, rp, plot.left - 4 - w, y - half, text, ink);
    }
    support.setPen(gb, rp, ink);
    gb.DrawVLine(rp, plot.left, plot.top, plot.height);

    // The series.
    const slot_w: i32 = @max(@divTrunc(plot.width, @as(i32, @intCast(own.capacity))), 1);
    for (0..own.series) |si| {
        const s: u32 = @intCast(si);
        const ring = own.rings[s];
        if (ring.count == 0) continue;
        const colour = if (ring.coloured != 0) ring.colour else if (s == 0) first else series_colours[s];
        support.setPen(gb, rp, colour);
        // The newest value at the right.
        const skip: i32 = @intCast(own.capacity - ring.count);
        if (own.kind == cr.CHART_BARS) {
            const bar_w: i32 = @max(@divTrunc(slot_w - 1, @as(i32, @intCast(own.series))), 1);
            const zero = yOf(plot, scale[0], span, @max(scale[0], @min(0, scale[1])));
            for (0..ring.count) |i| {
                const x = plot.left + 1 + (@as(i32, @intCast(i)) + skip) * slot_w + @as(i32, @intCast(s)) * bar_w;
                const y = yOf(plot, scale[0], span, valueAt(own, s, @intCast(i)));
                gb.RectFill(rp, &.{ .min_x = x, .min_y = @min(y, zero), .max_x = x + bar_w, .max_y = @max(y, zero) + 1 });
            }
        } else {
            gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} });
            defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} });
            for (0..ring.count) |i| {
                const x = plot.left + 1 + @divTrunc((@as(i32, @intCast(i)) + skip) * (plot.width - 2), @as(i32, @intCast(own.capacity - 1)));
                const y = yOf(plot, scale[0], span, valueAt(own, s, @intCast(i)));
                if (i == 0) gb.Move(rp, x, y) else gb.Draw(rp, x, y);
            }
        }
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
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
            own.series = @max(@min(@as(u32, @truncate(ub.GetTagData(cr.CHART_Series, 1, new.attr_list))), cr.CHART_MAX_SERIES), 1);
            own.capacity = @max(@min(@as(u32, @truncate(ub.GetTagData(cr.CHART_Capacity, 64, new.attr_list))), 1024), 2);
            own.values = @ptrCast(@alignCast(base.sys_base.AllocVec(own.series * own.capacity * 4, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendMessage(obj, &gone);
                return 0;
            }));
            _ = setAttrs(base, own, new.attr_list);
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) == null and ub.FindTagItem(gc.GA_Height, new.attr_list) == null) {
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = @intCast(nominal.width) },
                    .{ .tag = gc.GA_Height, .data = @intCast(nominal.height) },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            if (own.values) |values| base.sys_base.FreeVec(values);
            own.values = null;
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
                cr.CHART_Count => get.storage.* = own.rings[own.current].count,
                cr.CHART_Min => get.storage.* = @bitCast(@as(isize, @intCast(scaleOf(own)[0]))),
                cr.CHART_Max => get.storage.* = @bitCast(@as(isize, @intCast(scaleOf(own)[1]))),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = 60, .height = 40 },
                gc.GDOMAIN_NOMINAL => nominal,
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
            };
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
