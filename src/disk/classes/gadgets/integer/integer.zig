// SPDX-License-Identifier: MIT
//! integer.gadget: a number to type, held in a range, with arrows that
//! step it.
//!
//! The gadget is a `string.gadget` number field of its own with two arrow
//! buttons beside it, up over down, at its right end. The field is in no
//! window's list: this one places it before every message it hands on and
//! hands on the input with the pointer moved into its box. Its
//! `ICA_TARGET` is this gadget, which hears the number as it is typed.
//!
//! The number this gadget keeps is the one that counts: a number typed is
//! taken when the field is done with - brought into the range first - and
//! the field is told the number back whenever it is set from anywhere
//! else. A press on an arrow steps it and holds the gadget; the timer
//! events the active gadget is sent step it again once three have gone
//! by, then at each one, while the pointer stays on the arrow.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const ig = gadgets.integer;
const st = gadgets.string;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = ig.INTEGER_CLASS,
    .version = 1,
    .date = "28.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    // The field it makes is a string.gadget.
    .opens = &.{st.STRING_LIBRARY},
});
comptime {
    _ = Library;
}

/// Which arrow, if any.
const NONE: u8 = 0;
const UP: u8 = 1;
const DOWN: u8 = 2;

/// How many timer events an arrow is held for before it repeats.
const repeat_delay = 3;
/// The least an arrow button may be, along the way it points.
const least_arrow = 3;

/// integer.gadget's part of an object.
pub const Data = extern struct {
    number: i32 = 0,
    min: i32 = 0,
    max: i32 = 0x7FFF_FFFF,
    step: i32 = 1,
    /// How wide each arrow is; 0 for none.
    arrows: i32 = 0,
    /// The arrow being held, and whether the pointer is on it.
    held: u8 = NONE,
    over: u8 = 0,
    pad: [2]u8 = @splat(0),
    /// Timer events since the arrow was pressed.
    ticks: u32 = 0,
    /// The field: a string.gadget of this one's own.
    inner: ?*Object = null,
    /// The arrows' button frame.
    frame: ?*Object = null,
};

fn clamp(own: *Data) void {
    if (own.min > own.max) {
        const lowest = own.max;
        own.max = own.min;
        own.min = lowest;
    }
    own.number = @max(own.min, @min(own.number, own.max));
}

/// The field told the number, drawn at once in a window.
fn putNumber(base: *gadgets.Base, own: *const Data, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{ .{ .tag = gc.STRINGA_LongVal, .data = @bitCast(@as(isize, own.number)) }, .{} };
    var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
    _ = base.intuition_base.SendMessage(own.inner.?, @ptrCast(&set));
}

/// The target told the number.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const tags = [_]TagItem{
        .{ .tag = ig.INTEGER_Number, .data = @bitCast(@as(isize, own.number)) },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, flags);
}

/// The attributes among `tags`: whether the number or the range changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        const value: i32 = @truncate(@as(isize, @bitCast(item.data)));
        switch (item.tag) {
            ig.INTEGER_Number => {
                own.number = value;
                changed = true;
            },
            ig.INTEGER_Min => {
                own.min = value;
                changed = true;
            },
            ig.INTEGER_Max => {
                own.max = value;
                changed = true;
            },
            ig.INTEGER_Step => own.step = @max(value, 1),
            else => {},
        }
    }
    _ = new;
    clamp(own);
    return changed;
}

// --- where things are -------------------------------------------------------

/// The field and the two arrows in a box `size` big, relative to it: the
/// arrows at the right end, up over down.
const Parts = struct {
    field: gc.Box,
    up: gc.Box,
    down: gc.Box,

    fn of(own: *const Data, size: gc.Box) Parts {
        const width = @min(own.arrows, @max(size.width, 0));
        const field = gc.Box{ .width = size.width - width, .height = size.height };
        const half = @divTrunc(size.height, 2);
        return .{
            .field = field,
            .up = .{ .left = field.width, .width = width, .height = half },
            .down = .{ .left = field.width, .top = half, .width = width, .height = size.height - half },
        };
    }

    fn arrowAt(parts: Parts, own: *const Data, x: i32, y: i32) u8 {
        if (own.arrows == 0) return NONE;
        if (support.inside(x - parts.up.left, y - parts.up.top, parts.up.width, parts.up.height)) return UP;
        if (support.inside(x - parts.down.left, y - parts.down.top, parts.down.width, parts.down.height)) return DOWN;
        return NONE;
    }
};

fn partsOf(own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Parts {
    const b = gc.boxFor(gc.gadget(o), gi);
    return Parts.of(own, .{ .width = b.width, .height = b.height });
}

/// The field put where it belongs; its place in the gadget's box.
fn placeInner(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) gc.Box {
    const b = gc.boxFor(gc.gadget(o), gi);
    const at = partsOf(own, o, gi).field;
    support.place(base.intuition_base, own.inner.?, .{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height });
    return at;
}

// --- drawing ----------------------------------------------------------------

fn drawArrows(base: *gadgets.Base, own: *const Data, o: *Object, rp: *graphics.RastPort, info: *classusr.GadgetInfo) void {
    if (own.arrows == 0) return;
    const b = gc.boxFor(gc.gadget(o), info);
    const parts = partsOf(own, o, info);
    for ([_]u8{ UP, DOWN }) |which| {
        const part = if (which == UP) parts.up else parts.down;
        support.drawArrow(base.intuition_base, base.graphics_base, own.frame.?, rp, info.draw_info, .{
            .at = .{ .left = b.left + part.left, .top = b.top + part.top, .width = part.width, .height = part.height },
            .vertical = true,
            .forward = which == DOWN,
            .pressed = own.held == which and own.over != 0,
        });
    }
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    const saved = support.Saved.of(gb, r.rast_port);
    defer saved.restore(gb, r.rast_port);
    _ = placeInner(base, own, o, info);
    support.passMarks(o, own.inner.?);
    _ = base.intuition_base.SendMessage(own.inner.?, @ptrCast(r));
    drawArrows(base, own, o, r.rast_port, info);
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(gb, r.rast_port, gc.boxFor(gc.gadget(o), info), info.block_pen);
}

/// The arrows drawn again, if it is in a window.
fn redrawArrows(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const info = gi orelse return;
    const ib = base.intuition_base;
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const saved = support.Saved.of(base.graphics_base, rp);
    defer saved.restore(base.graphics_base, rp);
    drawArrows(base, own, o, rp, info);
}

/// One step of the arrow being held: the number moved, the field told and
/// the target told.
fn step(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const was = own.number;
    const moved: i64 = if (own.held == UP) @as(i64, own.number) + own.step else @as(i64, own.number) - own.step;
    own.number = @intCast(@max(@as(i64, own.min), @min(moved, own.max)));
    if (own.number == was) return;
    putNumber(base, own, gi);
    tell(base, own, o, gi, classusr.OPUF_INTERIM);
}

// --- sizes ------------------------------------------------------------------

/// Its size: the field's, and the arrows beside it. Never shorter than
/// two arrows will fit in.
fn domain(base: *gadgets.Base, own: *const Data, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    var ask = gc.GpDomain{ .gadget_info = @constCast(gi), .which = which };
    _ = ib.SendMessage(own.inner.?, @ptrCast(&ask));
    const width = if (ask.domain.width >= gc.GDOMAIN_UNLIMITED) gc.GDOMAIN_UNLIMITED else ask.domain.width + own.arrows;
    const height = if (own.arrows != 0) @max(ask.domain.height, 2 * least_arrow) else ask.domain.height;
    return .{ .width = width, .height = height };
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
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            // The field: a number field of string.gadget's, which takes
            // digits and a sign and nothing else.
            const inner_tags = [_]TagItem{
                .{ .tag = gc.STRINGA_LongVal, .data = @bitCast(@as(isize, own.number)) },
                .{ .tag = gc.STRINGA_MaxChars, .data = ub.GetTagData(gc.STRINGA_MaxChars, 12, new.attr_list) },
                .{ .tag = gc.STRINGA_Justification, .data = ub.GetTagData(gc.STRINGA_Justification, gc.GACT_STRINGRIGHT, new.attr_list) },
                .{ .tag = gc.GA_TabCycle, .data = ub.GetTagData(gc.GA_TabCycle, 0, new.attr_list) },
                .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(obj) },
                .{},
            };
            if (own.frame != null) own.inner = ib.NewObjectTagList(null, st.STRING_CLASS, &inner_tags);
            if (own.inner == null) {
                ib.DisposeObject(own.frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // The arrows are as wide as the field is tall, so that each
            // is about square; a gadget made without them is a field.
            if (ub.GetTagData(ig.INTEGER_Arrows, 1, new.attr_list) != 0) {
                var tall = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
                _ = ib.SendMessage(own.inner.?, @ptrCast(&tall));
                own.arrows = @max(tall.domain.height, 2 * least_arrow);
            }
            // Reported when a press ends; made without a size, as big as
            // it looks right.
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            const size = domain(base, own, null, gc.GDOMAIN_NOMINAL);
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
            const ub = base.utility_base;
            // The field saying what was typed: taken while it is being
            // typed, brought into the range when the field is done with,
            // and told on in this gadget's name.
            if (msg.method_id == classusr.OM_UPDATE) if (ub.FindTagItem(gc.STRINGA_LongVal, set.attr_list)) |item| {
                const update: *classusr.OpUpdate = @ptrCast(@alignCast(msg));
                own.number = @truncate(@as(isize, @bitCast(item.data)));
                if (update.flags & classusr.OPUF_INTERIM == 0) {
                    const typed = own.number;
                    clamp(own);
                    if (own.number != typed) putNumber(base, own, update.gadget_info);
                }
                tell(base, own, o.?, update.gadget_info, update.flags);
                return 0;
            };
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setAttrs(base, own, set.attr_list, false)) {
                // Drawn by the field itself when it is in a window.
                putNumber(base, own, set.gadget_info);
                changed = 1;
            }
            if (ub.FindTagItem(gc.GA_Disabled, set.attr_list)) |item| {
                const tags = [_]TagItem{ .{ .tag = gc.GA_Disabled, .data = item.data }, .{} };
                _ = ib.SetAttrsTagList(own.inner, &tags);
                if (classes.objectClass(o.?) == cl and set.gadget_info != null) {
                    support.redraw(ib, o.?, set.gadget_info);
                    return 0;
                }
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            switch (get.attr_id) {
                ig.INTEGER_Number => get.storage.* = @bitCast(@as(isize, own.number)),
                ig.INTEGER_Min => get.storage.* = @bitCast(@as(isize, own.min)),
                ig.INTEGER_Max => get.storage.* = @bitCast(@as(isize, own.max)),
                ig.INTEGER_Step => get.storage.* = @bitCast(@as(isize, own.step)),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), ask.gadget_info, ask.which);
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
        // The key gives the field the keyboard, as a press on it would.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            return if (gc.keyIsFor(o.?, k)) gc.GMKR_ACTIVATE else gc.GMKR_NOTHING;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (in.event == null) return gc.GMR_NOREUSE;
            const which = partsOf(own, o.?, in.gadget_info).arrowAt(own, in.mouse.x, in.mouse.y);
            if (which == NONE) {
                const at = placeInner(base, own, o.?, in.gadget_info);
                return support.handOnInput(ib, own.inner.?, in, at);
            }
            own.held = which;
            own.over = 1;
            own.ticks = 0;
            redrawArrows(base, own, o.?, in.gadget_info);
            step(base, own, o.?, in.gadget_info);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.held == NONE) {
                const at = placeInner(base, own, o.?, in.gadget_info);
                return support.handOnInput(ib, own.inner.?, in, at);
            }
            const e = in.event orelse return gc.GMR_MEACTIVE;
            const over: u8 = @intFromBool(partsOf(own, o.?, in.gadget_info).arrowAt(own, in.mouse.x, in.mouse.y) == own.held);
            if (over != own.over) {
                own.over = over;
                redrawArrows(base, own, o.?, in.gadget_info);
            }
            if (e.class == ie.IECLASS_TIMER) {
                own.ticks += 1;
                if (own.ticks > repeat_delay and own.over != 0) step(base, own, o.?, in.gadget_info);
                return gc.GMR_MEACTIVE;
            }
            if (e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                own.held = NONE;
                own.over = 0;
                redrawArrows(base, own, o.?, in.gadget_info);
                tell(base, own, o.?, in.gadget_info, 0);
                in.termination.* = own.number;
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.held != NONE) {
                own.held = NONE;
                own.over = 0;
                redrawArrows(base, own, o.?, gone.gadget_info);
            }
            _ = placeInner(base, own, o.?, gone.gadget_info);
            return ib.SendMessage(own.inner.?, msg);
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
