// SPDX-License-Identifier: MIT
//! calendar.gadget: a month to pick a day from.
//!
//! The box is a grid seven cells across and eight down: the month's line,
//! the weekdays, and six weeks. A cell is as wide as the widest of "00"
//! and a weekday's name with room either side, and a line of the font with
//! room above and below; the grid is centred in the box.
//!
//! **The month shown** is kept as the day number of its first day; the
//! first week shown starts on the last `CALENDAR_FirstWeekday` on or before
//! it. Days are split into dates by utility.library (`DateSplit`) and the
//! first of a month found by `DateJoin`.
//!
//! **A press** on an arrow turns the month and is done; on a day it
//! chooses that day, turns to its month if it was faded, and is a
//! `GADGETUP` whose code is the day number. Nothing follows the pointer.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const style = intuition.style;
const ie = sdk.devices.inputevent;
const dos = sdk.dos;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const ca = gadgets.calendar;
const DosBase = sdk.interface.dos.DosBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = ca.CALENDAR_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// calendar.gadget's part of an object.
pub const Data = extern struct {
    day: u32 = 0,
    today: u32 = 0,
    first_weekday: u32 = 1,
    mark_hook: ?*utility.Hook = null,
    /// The first day of the month shown.
    month_start: u32 = 0,
    /// The month's line, written.
    title: [24]u8 = @splat(0),
};

const month_names = [_][*:0]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const weekday_names = [_][*:0]const u8{ "Su", "Mo", "Tu", "We", "Th", "Fr", "Sa" };
/// Rows: the month's line, the weekdays, six weeks.
const rows = 8;
const weeks = 6;

/// The first day of the month `day` is in.
pub fn monthStart(ub: anytype, day: u32) u32 {
    var date: utility.ClockData = .{};
    ub.DateSplit(day, &date);
    return day - (date.mday - 1);
}

/// The first day of the month `months` away from the one starting on
/// `start`.
fn monthAway(ub: anytype, start: u32, months: i32) u32 {
    var date: utility.ClockData = .{};
    ub.DateSplit(start, &date);
    var index: i32 = @as(i32, date.year) * 12 + (date.month - 1) + months;
    index = @max(index, 1978 * 12);
    const moved = utility.ClockData{ .year = @intCast(@divTrunc(index, 12)), .month = @intCast(@mod(index, 12) + 1), .mday = 1 };
    const joined = ub.DateJoin(&moved);
    return if (joined < 0) start else @intCast(joined);
}

/// The first day of the six weeks shown for the month starting on `start`.
pub fn gridStart(ub: anytype, start: u32, first_weekday: u32) u32 {
    var date: utility.ClockData = .{};
    ub.DateSplit(start, &date);
    const back = (date.wday + 7 - first_weekday) % 7;
    return if (start >= back) start - back else 0;
}

/// The grid's cell, and where the grid starts in a box.
const Grid = struct { left: i32, top: i32, cell_w: i32, cell_h: i32 };

fn gridIn(b: gc.Box, cell_w: i32, cell_h: i32) Grid {
    return .{
        .left = b.left + @divTrunc(b.width - 7 * cell_w, 2),
        .top = b.top + @divTrunc(b.height - rows * cell_h, 2),
        .cell_w = cell_w,
        .cell_h = cell_h,
    };
}

/// A cell's size in a font: the widest of "00" and the weekdays, with room.
fn cellSize(width_of: anytype, line: i32) [2]i32 {
    var widest = width_of.width("00");
    for (weekday_names) |name| widest = @max(widest, width_of.width(name));
    return .{ widest + 8, line + 4 };
}

/// Text widths on a RastPort.
const OnRastPort = struct {
    gb: *sdk.interface.graphics.GraphicsBase,
    rp: *graphics.RastPort,
    fn width(m: OnRastPort, text: [*:0]const u8) i32 {
        return m.gb.TextLength(m.rp, text, support.textLen(text));
    }
};

/// Text widths in a gadget's font, before it is drawn.
const InFont = struct {
    ib: *sdk.interface.intuition.IntuitionBase,
    measure: support.Measure,
    fn width(m: InFont, text: [*:0]const u8) i32 {
        return m.measure.width(m.ib, text);
    }
};

fn todayFromDos(base: *gadgets.Base) u32 {
    const lib = base.sys_base.OpenLibrary(dos.DOSNAME, 0) orelse return 0;
    defer base.sys_base.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var stamp: dos.DateStamp = .{};
    _ = dl.DateStamp(&stamp);
    return @intCast(@max(stamp.days, 0));
}

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    var changed = false;
    var state = tags;
    while (base.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            ca.CALENDAR_Day => {
                own.day = @truncate(item.data);
                own.month_start = monthStart(base.utility_base, own.day);
            },
            ca.CALENDAR_Today => own.today = @truncate(item.data),
            ca.CALENDAR_FirstWeekday => own.first_weekday = @as(u32, @truncate(item.data)) % 7,
            ca.CALENDAR_MarkHook => own.mark_hook = @ptrFromInt(item.data),
            else => continue,
        }
        changed = true;
    }
    return changed;
}

fn centred(gb: anytype, rp: *graphics.RastPort, left: i32, top: i32, width: i32, height: i32, line: i32, text: [*:0]const u8, pen: Pen) void {
    const w = gb.TextLength(rp, text, support.textLen(text));
    support.drawText(gb, rp, left + @divTrunc(width - w, 2), top + @divTrunc(height - line, 2), text, pen);
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const ub = base.utility_base;
    const rp = r.rast_port;
    const own = classes.instData(Data, cl, o);
    const g = gc.gadget(o);
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);

    const b = gc.boxFor(g, info);
    const dri = info.draw_info;
    const ground = support.background(ib, dri, g.style, style.PART_MAIN);
    const ink: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_MAIN, style.STATE_NORMAL, style.STYLE_TextPen));
    const chosen: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_SELECTION, style.STATE_NORMAL, style.STYLE_Background));
    const chosen_ink: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_SELECTION, style.STATE_NORMAL, style.STYLE_TextPen));
    const ring: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_INDICATOR, style.STATE_NORMAL, style.STYLE_Background));
    const faded = support.mixPens(ink, ground, 7);
    support.fill(gb, rp, b, ground);

    var line_u: u32 = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line_u) }, .{} });
    const line: i32 = @intCast(line_u);
    const size = cellSize(OnRastPort{ .gb = gb, .rp = rp }, line);
    const grid = gridIn(b, size[0], size[1]);

    // The month's line: the arrows at the ends, the month in the middle.
    var date: utility.ClockData = .{};
    ub.DateSplit(own.month_start, &date);
    const stream = extern struct { name: [*:0]const u8, year: u32 }{ .name = month_names[date.month - 1], .year = date.year };
    _ = support.formatInto(base.sys_base, "%s %u", &stream, &own.title);
    centred(gb, rp, grid.left, grid.top, grid.cell_w, grid.cell_h, line, "<", ink);
    centred(gb, rp, grid.left + 6 * grid.cell_w, grid.top, grid.cell_w, grid.cell_h, line, ">", ink);
    centred(gb, rp, grid.left + grid.cell_w, grid.top, 5 * grid.cell_w, grid.cell_h, line, @ptrCast(&own.title), ink);

    // The weekdays.
    for (0..7) |column| {
        const weekday = (own.first_weekday + column) % 7;
        centred(gb, rp, grid.left + @as(i32, @intCast(column)) * grid.cell_w, grid.top + grid.cell_h, grid.cell_w, grid.cell_h, line, weekday_names[weekday], faded);
    }

    // The weeks.
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 1 }, .{} });
    defer gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} });
    const first = gridStart(ub, own.month_start, own.first_weekday);
    for (0..weeks * 7) |cell| {
        const day: u32 = first + @as(u32, @intCast(cell));
        var split: utility.ClockData = .{};
        ub.DateSplit(day, &split);
        const left = grid.left + @as(i32, @intCast(cell % 7)) * grid.cell_w;
        const top = grid.top + @as(i32, @intCast(2 + cell / 7)) * grid.cell_h;
        const box = graphics.Rect{ .min_x = left + 1, .min_y = top, .max_x = left + grid.cell_w - 1, .max_y = top + grid.cell_h };
        var pen = if (split.month == date.month) ink else faded;
        if (day == own.day) {
            support.setPen(gb, rp, chosen);
            gb.FillRoundRect(rp, &box, 4);
            pen = chosen_ink;
        }
        if (day == own.today and own.today != 0) {
            support.setPen(gb, rp, ring);
            gb.DrawRoundRect(rp, &box, 4);
        }
        var digits: [4]u8 = undefined;
        centred(gb, rp, left, top, grid.cell_w, grid.cell_h, line, support.formatNumber(base.sys_base, "%ld", split.mday, &digits), pen);
        if (own.mark_hook) |hook| {
            if (hook.entry.?(hook, o, @ptrCast(@constCast(&day))) != 0) {
                support.setPen(gb, rp, pen);
                gb.FillArc(rp, &.{ .cx = left + @divTrunc(grid.cell_w, 2), .cy = top + grid.cell_h - 2, .radius = 1 });
            }
        }
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// The target told the chosen day.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = ca.CALENDAR_Day, .data = own.day },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

/// The cell size in the gadget's font.
fn cellFor(base: *gadgets.Base, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) [2]i32 {
    const measure = support.Measure.of(base.intuition_base, g, gi);
    defer measure.done(base.intuition_base);
    return cellSize(InFont{ .ib = base.intuition_base, .measure = measure }, measure.lineHeight(base.graphics_base));
}

fn press(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const g = gc.gadget(o);
    const b = gc.boxFor(g, in.gadget_info);
    const size = cellFor(base, g, in.gadget_info);
    const grid = gridIn(.{ .width = b.width, .height = b.height }, size[0], size[1]);
    const column = @divFloor(in.mouse.x - grid.left, grid.cell_w);
    const row = @divFloor(in.mouse.y - grid.top, grid.cell_h);
    if (column < 0 or column > 6 or row < 0 or row >= rows) return gc.GMR_NOREUSE;
    if (row == 0) {
        if (column != 0 and column != 6) return gc.GMR_NOREUSE;
        own.month_start = monthAway(base.utility_base, own.month_start, if (column == 0) -1 else 1);
        support.redraw(base.intuition_base, o, in.gadget_info);
        return gc.GMR_NOREUSE;
    }
    if (row == 1) return gc.GMR_NOREUSE;
    const first = gridStart(base.utility_base, own.month_start, own.first_weekday);
    own.day = first + @as(u32, @intCast((row - 2) * 7 + column));
    own.month_start = monthStart(base.utility_base, own.day);
    support.redraw(base.intuition_base, o, in.gadget_info);
    tell(base, own, o, in.gadget_info);
    in.termination.* = @bitCast(own.day);
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
            const ub = base.utility_base;
            own.today = if (ub.FindTagItem(ca.CALENDAR_Today, new.attr_list) == null) todayFromDos(base) else 0;
            own.day = own.today;
            own.month_start = monthStart(ub, own.day);
            _ = setAttrs(base, own, new.attr_list);
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) == null and ub.FindTagItem(gc.GA_Height, new.attr_list) == null) {
                const size = cellFor(base, gc.gadget(obj), null);
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = @intCast(7 * size[0]) },
                    .{ .tag = gc.GA_Height, .data = @intCast(rows * size[1]) },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
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
                ca.CALENDAR_Day => get.storage.* = own.day,
                ca.CALENDAR_Today => get.storage.* = own.today,
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const size = cellFor(base, gc.gadget(o.?), ask.gadget_info);
            ask.domain = if (ask.which == gc.GDOMAIN_MAXIMUM)
                .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED }
            else
                .{ .width = 7 * size[0], .height = rows * size[1] };
            return 1;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            return press(base, classes.instData(Data, cl, o.?), o.?, in);
        },
        // The key moves to the next day, and back with a Shift key held.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            const back = k.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
            if (back and own.day == 0) return gc.GMKR_DONE;
            own.day = if (back) own.day - 1 else own.day + 1;
            own.month_start = monthStart(base.utility_base, own.day);
            support.redraw(ib, o.?, k.gadget_info);
            tell(base, own, o.?, k.gadget_info);
            k.termination.* = @bitCast(own.day);
            return gc.GMKR_VERIFY;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
