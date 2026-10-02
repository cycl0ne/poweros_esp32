// SPDX-License-Identifier: MIT
//! meter.gadget: a dial with a scale and a needle.
//!
//! A gadgetclass gadget that is never pressed and draws in `GM_RENDER`:
//! its box cleared to the gadget's background, then the scale - a thin
//! ring over the sweep, the band's part of it thicker in the band's
//! colour - its ticks and, on a dial of 80 pixels or more, the numbers at
//! the long ticks; then the needle from the middle to near the scale and
//! the hub over its foot, in the style's indicator colour, and the level
//! written under the hub when a format is given. Everything round is drawn
//! with smooth edges.
//!
//! The needle's angle is the shown level's (`moving.Moving`), which goes
//! to a new level on motion.library's clock.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const style = intuition.style;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const angles = gadgets.angles;
const mt = gadgets.meter;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = mt.METER_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// meter.gadget's part of an object.
pub const Data = extern struct {
    min: i32 = 0,
    max: i32 = 100,
    level: i32 = 0,
    start: i32 = 225,
    sweep: i32 = 270,
    ticks: u32 = 10,
    minor: u32 = 2,
    format: ?[*:0]const u8 = null,
    band: i32 = 0,
    has_band: u32 = 0,
    band_rgb: Pen = 0xFFC0_3030,
    /// The level the needle shows, on its way to `level`.
    needle: gadgets.moving.Moving = .{},
    /// The level as text.
    written: [24]u8 = @splat(0),
};

/// How long the needle takes to a new level.
const swing_time = 250;
/// Its size when it is given none, and at the least.
const nominal_size = 96;
const least_size = 32;
/// The size from which numbers are written at the long ticks.
const numbers_from = 80;

/// The angle of `value` on the scale.
fn angleAt(own: *const Data, value: i32) i32 {
    const span: i64 = own.max - own.min;
    if (span <= 0) return own.start;
    const along: i64 = @as(i64, @max(own.min, @min(value, own.max))) - own.min;
    return own.start - @as(i32, @intCast(@divTrunc(along * own.sweep, span)));
}

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    var changed = false;
    var state = tags;
    while (base.utility_base.NextTagItem(&state)) |item| {
        const signed: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            mt.METER_Min => own.min = signed,
            mt.METER_Max => own.max = signed,
            mt.METER_Level => own.level = signed,
            mt.METER_Start => own.start = signed,
            mt.METER_Sweep => own.sweep = @max(@min(signed, 360), 1),
            mt.METER_Ticks => own.ticks = @max(@as(u32, @truncate(item.data)), 1),
            mt.METER_Minor => own.minor = @max(@as(u32, @truncate(item.data)), 1),
            mt.METER_Format => own.format = @ptrFromInt(item.data),
            mt.METER_Band => {
                own.band = signed;
                own.has_band = 1;
            },
            mt.METER_BandRGB => own.band_rgb = @truncate(item.data),
            else => continue,
        }
        changed = true;
    }
    if (own.max < own.min) own.max = own.min;
    own.level = @max(own.min, @min(own.level, own.max));
    return changed;
}

/// A line from `radius_in` to `radius_out` at `degrees`.
fn spoke(gb: anytype, rp: *graphics.RastPort, cx: i32, cy: i32, radius_in: i32, radius_out: i32, degrees: i32) void {
    const from = angles.pointAt(cx, cy, radius_in, degrees);
    const to = angles.pointAt(cx, cy, radius_out, degrees);
    gb.Move(rp, from[0], from[1]);
    gb.Draw(rp, to[0], to[1]);
}

/// `text` centred on (`cx`, `cy`).
fn centredText(gb: anytype, rp: *graphics.RastPort, cx: i32, cy: i32, text: [*:0]const u8, pen: Pen) void {
    var line: u32 = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) }, .{} });
    const width = gb.TextLength(rp, text, support.textLen(text));
    support.drawText(gb, rp, cx - @divTrunc(width, 2), cy - @divTrunc(@as(i32, @intCast(line)), 2), text, pen);
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
    const ground = support.background(ib, info.draw_info, g.style, style.PART_MAIN);
    const ink: Pen = @truncate(ib.GetStyleAttr(info.draw_info, g.style, style.PART_MAIN, style.STATE_NORMAL, style.STYLE_TextPen));
    const needle_pen: Pen = @truncate(ib.GetStyleAttr(info.draw_info, g.style, style.PART_INDICATOR, style.STATE_NORMAL, style.STYLE_Background));
    support.fill(gb, rp, b, ground);

    const size = @min(b.width, b.height);
    const radius: i32 = @divTrunc(size, 2) - 2;
    if (radius < 6) return;
    const cx = b.left + @divTrunc(b.width, 2);
    const cy = b.top + @divTrunc(b.height, 2);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} });
    defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} });

    // The scale, and the band over its end.
    const end = own.start - own.sweep;
    support.setPen(gb, rp, ink);
    gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = radius, .inner = radius - 1, .from = end, .to = own.start });
    if (own.has_band != 0 and own.band < own.max) {
        support.setPen(gb, rp, own.band_rgb);
        gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = radius, .inner = radius - 4, .from = end, .to = angleAt(own, own.band) });
    }

    // The ticks, and the numbers at the long ones.
    support.setPen(gb, rp, ink);
    const steps = own.ticks * own.minor;
    const numbered = size >= numbers_from;
    var i: u32 = 0;
    while (i <= steps) : (i += 1) {
        const degrees = own.start - @as(i32, @intCast(@divTrunc(@as(i64, own.sweep) * i, steps)));
        const long = i % own.minor == 0;
        spoke(gb, rp, cx, cy, radius - (if (long) @as(i32, 7) else 4), radius - 1, degrees);
        if (long and numbered) {
            const value = own.min + @as(i32, @intCast(@divTrunc(@as(i64, own.max - own.min) * i, steps)));
            var digits: [16]u8 = undefined;
            const at = angles.pointAt(cx, cy, radius - 15, degrees);
            centredText(gb, rp, at[0], at[1], support.formatNumber(base.sys_base, "%ld", value, &digits), ink);
            support.setPen(gb, rp, ink);
        }
    }

    // The level, under the hub.
    if (own.format) |format| {
        centredText(gb, rp, cx, cy + @divTrunc(radius, 2), support.formatNumber(base.sys_base, format, own.needle.shown, &own.written), ink);
    }

    // The needle, and the hub over its foot.
    support.setPen(gb, rp, needle_pen);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_LineWidth, .data = 2 }, .{} });
    spoke(gb, rp, cx, cy, 0, radius - 9, angleAt(own, own.needle.shown));
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_LineWidth, .data = 1 }, .{} });
    gb.FillArc(rp, &.{ .cx = cx, .cy = cy, .radius = @max(@divTrunc(radius, 12), 2) });
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
            _ = setAttrs(base, own, new.attr_list);
            own.needle.shown = own.level;
            const ub = base.utility_base;
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) == null and ub.FindTagItem(gc.GA_Height, new.attr_list) == null) {
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = nominal_size },
                    .{ .tag = gc.GA_Height, .data = nominal_size },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            classes.instData(Data, cl, o orelse return 0).needle.dispose(base);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            const own = classes.instData(Data, cl, o.?);
            if (setAttrs(base, own, set.attr_list)) changed = 1;
            // A new level swings the needle there, drawing as it goes.
            if (own.needle.shown != own.level and own.needle.towards(base, o.?, set.gadget_info, own.level, swing_time)) return 0;
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
                mt.METER_Level => get.storage.* = @bitCast(@as(isize, own.level)),
                mt.METER_Min => get.storage.* = @bitCast(@as(isize, own.min)),
                mt.METER_Max => get.storage.* = @bitCast(@as(isize, own.max)),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const side: i32 = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => least_size,
                gc.GDOMAIN_NOMINAL => nominal_size,
                else => gc.GDOMAIN_UNLIMITED,
            };
            ask.domain = .{ .width = side, .height = side };
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
