// SPDX-License-Identifier: MIT
//! roller.gadget: a wheel of choices turned by dragging.
//!
//! **Where it is** is a position in pixels down the list of rows, a row's
//! height to a row: 0 has the first row in the middle band. It is the
//! shown value of a `moving.Moving`, so a drag sets it at once and a
//! settling or a program's choice moves it there over a moment. With
//! `ROLLER_Wrap` the position is not held to the list: a row is the
//! position's row modulo the count, so the wheel turns round for ever.
//!
//! **Drawing** clears the box, fills the middle band in the selection
//! colour, and writes each row that fits inside the box whole, centred,
//! in the selection's text colour inside the band and further out mixed
//! towards the background by its distance from the middle. A row that
//! would stand over the box's edge is left out: a gadget's drawing is not
//! clipped to its box.
//!
//! **A press** goes active and keeps where it landed and where the wheel
//! was; a move turns the wheel by the pointer's travel. Letting go settles
//! on the nearest row - or, after a press that moved less than a few
//! pixels, on the row it landed on - and tells the target and the program.
//! The menu button puts back where it was.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sc = intuition.screens;
const style = intuition.style;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const ro = gadgets.roller;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = ro.ROLLER_CLASS,
    .version = 1,
    .date = "02.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

const Labels = [*:null]const ?[*:0]const u8;

/// roller.gadget's part of an object.
pub const Data = extern struct {
    labels: ?Labels = null,
    count: u32 = 0,
    selected: u32 = 0,
    rows: u32 = 5,
    wrap: u32 = 0,
    /// A row's height, as last measured.
    row_height: i32 = 12,
    /// Where the wheel is, in pixels down the rows.
    position: gadgets.moving.Moving = .{},
    /// A press: where it landed, and where the wheel was.
    press_y: i32 = 0,
    press_position: i32 = 0,
    moved: u32 = 0,
};

const settle_time = 200;
/// How far a press may move and still be a tap on a row.
const tap_slack = 4;
/// Room either side of the widest label.
const side_room = 10;

fn countOf(labels: ?Labels) u32 {
    const list = labels orelse return 0;
    var n: u32 = 0;
    while (list[n] != null) n += 1;
    return n;
}

/// The row at a position: the nearest, held to the list or wrapped round.
pub fn rowAt(own: *const Data, position: i32) u32 {
    if (own.count == 0) return 0;
    const row = @divFloor(position + @divTrunc(own.row_height, 2), own.row_height);
    if (own.wrap != 0) return @intCast(@mod(row, @as(i32, @intCast(own.count))));
    return @intCast(@max(0, @min(row, @as(i32, @intCast(own.count)) - 1)));
}

/// Where row `row` stands in the band, nearest to `from` when it wraps.
fn positionOf(own: *const Data, row: u32, from: i32) i32 {
    const exact: i32 = @as(i32, @intCast(row)) * own.row_height;
    if (own.wrap == 0 or own.count == 0) return exact;
    const turn: i32 = @as(i32, @intCast(own.count)) * own.row_height;
    const turns = @divFloor(from - exact + @divTrunc(turn, 2), turn);
    return exact + turns * turn;
}

/// The position held inside the list, when it does not wrap.
fn held(own: *const Data, position: i32) i32 {
    if (own.wrap != 0 or own.count == 0) return position;
    return @max(0, @min(position, (@as(i32, @intCast(own.count)) - 1) * own.row_height));
}

fn rowHeight(base: *gadgets.Base, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo) i32 {
    const measure = support.Measure.of(base.intuition_base, g, gi);
    defer measure.done(base.intuition_base);
    return measure.lineHeight(base.graphics_base) + 4;
}

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    var changed = false;
    var state = tags;
    while (base.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            ro.ROLLER_Labels => {
                own.labels = @ptrFromInt(item.data);
                own.count = countOf(own.labels);
            },
            ro.ROLLER_Selected => own.selected = @truncate(item.data),
            ro.ROLLER_Rows => if (new) {
                own.rows = @max(@as(u32, @truncate(item.data)) | 1, 1);
            },
            ro.ROLLER_Wrap => own.wrap = @intFromBool(item.data != 0),
            else => continue,
        }
        changed = true;
    }
    if (own.count == 0) own.selected = 0 else if (own.selected >= own.count) own.selected = own.count - 1;
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
    const band_pen: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_SELECTION, style.STATE_NORMAL, style.STYLE_Background));
    const band_ink: Pen = @truncate(ib.GetStyleAttr(dri, g.style, style.PART_SELECTION, style.STATE_NORMAL, style.STYLE_TextPen));
    support.fill(gb, rp, b, ground);

    var line: u32 = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) }, .{} });
    own.row_height = @as(i32, @intCast(line)) + 4;
    const row_height = own.row_height;
    const middle = b.top + @divTrunc(b.height, 2);
    const band = gc.Box{ .left = b.left, .top = middle - @divTrunc(row_height, 2), .width = b.width, .height = row_height };
    support.fill(gb, rp, band, band_pen);

    const labels = own.labels orelse return;
    if (own.count == 0) return;
    const position = own.position.shown;
    const first = @divFloor(position, row_height) - @as(i32, @intCast(own.rows / 2)) - 1;
    var index = first;
    while (index <= first + @as(i32, @intCast(own.rows)) + 2) : (index += 1) {
        if (own.wrap == 0 and (index < 0 or index >= @as(i32, @intCast(own.count)))) continue;
        const row: u32 = @intCast(@mod(index, @as(i32, @intCast(own.count))));
        // The row's middle, and its distance from the band's.
        const centre = middle + index * row_height - position;
        const top = centre - @divTrunc(@as(i32, @intCast(line)), 2);
        if (top < b.top or top + @as(i32, @intCast(line)) > b.top + b.height) continue;
        const away: u32 = @intCast(@abs(centre - middle));
        const text = labels[row] orelse continue;
        const fade: u32 = @min(away * 12 / @as(u32, @intCast(@max(b.height, 1))), 12);
        const pen = if (away * 2 < @as(u32, @intCast(row_height))) band_ink else support.mixPens(ink, ground, 16 - fade);
        const width = gb.TextLength(rp, text, support.textLen(text));
        support.drawText(gb, rp, b.left + @divTrunc(b.width - width, 2), top, text, pen);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// The target told the chosen row.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const tags = [_]TagItem{
        .{ .tag = ro.ROLLER_Selected, .data = own.selected },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, flags);
}

/// `selected` made the chosen row and the wheel turned to it.
fn turnTo(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, row: u32) void {
    own.selected = row;
    const target = positionOf(own, row, own.position.shown);
    if (!own.position.towards(base, o, gi, target, settle_time)) support.redraw(base.intuition_base, o, gi);
}

fn handle(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput) usize {
    const e = in.event orelse return gc.GMR_MEACTIVE;
    if (e.class != ie.IECLASS_NEWPOINTERPOS) return gc.GMR_MEACTIVE;
    if (e.code == ie.IECODE_RBUTTON) {
        _ = own.position.jump(own.press_position);
        support.redraw(base.intuition_base, o, in.gadget_info);
        in.termination.* = @intCast(own.selected);
        return gc.GMR_NOREUSE;
    }
    const travel = in.mouse.y - own.press_y;
    if (@abs(travel) > tap_slack) own.moved = 1;
    if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
        const b = gc.boxFor(gc.gadget(o), in.gadget_info);
        const landed = own.press_position + (own.press_y - @divTrunc(b.height, 2));
        const row = rowAt(own, if (own.moved != 0) own.position.shown else held(own, landed));
        turnTo(base, own, o, in.gadget_info, row);
        in.termination.* = @intCast(own.selected);
        tell(base, own, o, in.gadget_info, 0);
        return gc.GMR_NOREUSE | gc.GMR_VERIFY;
    }
    if (own.moved != 0) {
        _ = own.position.jump(held(own, own.press_position - travel));
        support.redraw(base.intuition_base, o, in.gadget_info);
    }
    return gc.GMR_MEACTIVE;
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
            own.row_height = rowHeight(base, gc.gadget(obj), null);
            own.position.shown = positionOf(own, own.selected, 0);
            const ub = base.utility_base;
            if (ub.FindTagItem(gc.GA_Width, new.attr_list) == null and ub.FindTagItem(gc.GA_Height, new.attr_list) == null) {
                var size: gc.GpDomain = .{ .which = gc.GDOMAIN_NOMINAL };
                _ = ib.SendMessage(obj, @ptrCast(&size));
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = @intCast(size.domain.width) },
                    .{ .tag = gc.GA_Height, .data = @intCast(size.domain.height) },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            return made;
        },
        classusr.OM_DISPOSE => {
            classes.instData(Data, cl, o orelse return 0).position.dispose(base);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            const own = classes.instData(Data, cl, o.?);
            const was = own.selected;
            const relabelled = base.utility_base.FindTagItem(ro.ROLLER_Labels, set.attr_list) != null;
            if (setAttrs(base, own, set.attr_list, false)) changed = 1;
            if (relabelled) {
                _ = own.position.jump(positionOf(own, own.selected, 0));
            } else if (own.selected != was) {
                const target = positionOf(own, own.selected, own.position.shown);
                if (own.position.towards(base, o.?, set.gadget_info, target, settle_time)) return 0;
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
                ro.ROLLER_Selected => get.storage.* = own.selected,
                ro.ROLLER_Labels => get.storage.* = @intFromPtr(own.labels),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const g = gc.gadget(o.?);
            const row_height = rowHeight(base, g, ask.gadget_info);
            var widest: i32 = 0;
            if (own.labels) |labels| {
                const measure = support.Measure.of(ib, g, ask.gadget_info);
                defer measure.done(ib);
                for (0..own.count) |i| widest = @max(widest, measure.width(ib, labels[i].?));
            }
            const width = widest + 2 * side_room;
            ask.domain = switch (ask.which) {
                gc.GDOMAIN_MINIMUM => .{ .width = width, .height = 3 * row_height },
                gc.GDOMAIN_NOMINAL => .{ .width = width, .height = @as(i32, @intCast(own.rows)) * row_height },
                else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = @as(i32, @intCast(own.rows)) * row_height },
            };
            return 1;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            if (own.count == 0) return gc.GMR_NOREUSE;
            _ = own.position.jump(own.position.shown);
            own.press_y = in.mouse.y;
            own.press_position = own.position.shown;
            own.moved = 0;
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => return handle(base, classes.instData(Data, cl, o.?), o.?, @ptrCast(@alignCast(msg))),
        // A choice per notch, down for the next, turned to as a key turns
        // it.
        gc.GM_WHEEL => {
            const wh: *gc.GpWheel = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const notches = gc.wheelNotches(wh, true);
            if (notches == 0 or own.count == 0) return 0;
            const count: i64 = own.count;
            var to = @as(i64, own.selected) + notches;
            to = if (own.wrap != 0) @mod(to, count) else @max(@min(to, count - 1), 0);
            if (to != own.selected) {
                turnTo(base, own, o.?, wh.gadget_info, @intCast(to));
                tell(base, own, o.?, wh.gadget_info, 0);
                return gc.wheelVerify(wh, @intCast(to));
            }
            return gc.GMWR_TAKEN;
        },
        // The key turns it a row, back with a Shift key held.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            if (own.count == 0) return gc.GMKR_NOTHING;
            const back = k.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
            const row: u32 = if (back)
                (if (own.selected > 0) own.selected - 1 else if (own.wrap != 0) own.count - 1 else 0)
            else if (own.selected + 1 < own.count) own.selected + 1 else if (own.wrap != 0) 0 else own.selected;
            if (row == own.selected) return gc.GMKR_DONE;
            turnTo(base, own, o.?, k.gadget_info, row);
            tell(base, own, o.?, k.gadget_info, 0);
            k.termination.* = @intCast(own.selected);
            return gc.GMKR_VERIFY;
        },
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
