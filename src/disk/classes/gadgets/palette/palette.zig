// SPDX-License-Identifier: MIT
//! palette.gadget: a grid of colour boxes, of which one is picked.
//!
//! A gadgetclass gadget in a button frame. The boxes are laid out anew
//! for the box it is drawn in: of every way of putting the colours in
//! whole rows and columns, the one whose boxes come nearest to square,
//! with room between them; when no way gives boxes of the least size, one
//! colour fewer is shown and it looks again. Each box is its colour, a
//! little in from its edges; the picked one sits in a pressed button frame
//! of its own.
//!
//! A press picks the box under the pointer and holds the gadget; the pick
//! follows the pointer, and let go, it ends the way that counts with the
//! box's number as the code. The right button while it is held puts back
//! what was picked when the press began, and ends it without a report.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const pa = gadgets.palette;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = pa.PALETTE_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// The least a colour box may be, inside its room, and the room between.
const least_width = 4;
const least_height = 3;
const gap_x = 3;
const gap_y = 1;
/// A box's room as it looks right.
const nominal_cell = 16;

/// palette.gadget's part of an object.
pub const Data = extern struct {
    table: ?[*]const Pen = null,
    num_colors: u32 = 0,
    color: u32 = 0,
    /// The pick when the press began, for the right button to put back.
    backup: u32 = 0,
    sized: u8 = 0,
    pad: [3]u8 = @splat(0),
    /// The gadget's frame, and the picked box's.
    frame: ?*Object = null,
    pick_frame: ?*Object = null,
};

/// The boxes' arrangement: how many across and down, and how many of the
/// colours are shown.
pub const Grid = struct {
    columns: u32,
    rows: u32,
    shown: u32,
};

/// The rows and columns that make boxes nearest to square in a room
/// `width` by `height`; one colour fewer each time none fits.
pub fn gridFor(count: u32, width: i32, height: i32) ?Grid {
    var colors = count;
    while (colors > 0) : (colors -= 1) {
        var best: ?Grid = null;
        var best_distance: i64 = 0;
        var divisor: u32 = 1;
        while (divisor <= colors) : (divisor += 1) {
            if (colors % divisor != 0) continue;
            const columns = colors / divisor;
            const rows = divisor;
            const box_w = @divTrunc(width, @as(i32, @intCast(columns))) - gap_x;
            const box_h = @divTrunc(height, @as(i32, @intCast(rows))) - gap_y;
            if (box_w < least_width or box_h < least_height) continue;
            // How far from square, in 256ths.
            const ratio = @divTrunc(@as(i64, box_w) * 256, box_h);
            const distance: i64 = @intCast(@abs(256 - ratio));
            if (best == null or distance < best_distance) {
                best = .{ .columns = columns, .rows = rows, .shown = colors };
                best_distance = distance;
            }
        }
        if (best) |grid| return grid;
    }
    return null;
}

/// The colours, and how many: the table, or the screen's pens.
fn colours(own: *const Data, dri: ?*const intuition.DrawInfo) struct { pens: ?[*]const Pen, count: u32 } {
    if (own.table) |table| return .{ .pens = table, .count = own.num_colors };
    const info = dri orelse return .{ .pens = null, .count = sc.NUMDRIPENS };
    return .{ .pens = info.pens, .count = if (own.num_colors != 0) @min(own.num_colors, info.num_pens) else info.num_pens };
}

/// The room the boxes share, relative to the gadget's box.
fn room(base: *gadgets.Base, own: *const Data, size: gc.Box, dri: ?*intuition.DrawInfo) gc.Box {
    const inset = support.frameInset(base.intuition_base, own.frame.?, dri);
    return .{ .left = inset.left, .top = inset.top, .width = size.width - inset.width, .height = size.height - inset.height };
}

/// The box a point in the room is over, pulled into the grid.
pub fn boxAt(grid: Grid, area: gc.Box, x: i32, y: i32) u32 {
    const cell_w = @divTrunc(area.width, @as(i32, @intCast(grid.columns)));
    const cell_h = @divTrunc(area.height, @as(i32, @intCast(grid.rows)));
    const column: u32 = @intCast(@max(0, @min(@divFloor(x - area.left, @max(cell_w, 1)), @as(i32, @intCast(grid.columns)) - 1)));
    const row: u32 = @intCast(@max(0, @min(@divFloor(y - area.top, @max(cell_h, 1)), @as(i32, @intCast(grid.rows)) - 1)));
    return @min(row * grid.columns + column, grid.shown - 1);
}

/// One box drawn, picked or not, at its place in `area` (window
/// coordinates).
fn drawBox(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, info: *classusr.GadgetInfo, grid: Grid, area: gc.Box, pens: [*]const Pen, ground: Pen, index: u32) void {
    const gb = base.graphics_base;
    const cell_w = @divTrunc(area.width, @as(i32, @intCast(grid.columns)));
    const cell_h = @divTrunc(area.height, @as(i32, @intCast(grid.rows)));
    const cell = gc.Box{
        .left = area.left + @as(i32, @intCast(index % grid.columns)) * cell_w,
        .top = area.top + @as(i32, @intCast(index / grid.columns)) * cell_h,
        .width = cell_w,
        .height = cell_h,
    };
    // The cell's ground, then the colour a little in from its edges.
    support.fill(gb, rp, cell, ground);
    if (index == own.color) support.drawFrame(base.intuition_base, own.pick_frame.?, rp, cell, ic.IDS_SELECTED, info.draw_info);
    const in: i32 = if (index == own.color) 2 else 1;
    support.fill(gb, rp, .{ .left = cell.left + in + 1, .top = cell.top + in, .width = cell.width - 2 * (in + 1), .height = cell.height - 2 * in }, pens[index]);
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    const saved = support.Saved.of(gb, r.rast_port);
    defer saved.restore(gb, r.rast_port);
    const b = gc.boxFor(gc.gadget(o), info);
    support.drawFrame(base.intuition_base, own.frame.?, r.rast_port, b, ic.IDS_NORMAL, info.draw_info);
    const have = colours(own, info.draw_info);
    const pens = have.pens orelse return;
    const inside = room(base, own, .{ .width = b.width, .height = b.height }, info.draw_info);
    const area = gc.Box{ .left = b.left + inside.left, .top = b.top + inside.top, .width = inside.width, .height = inside.height };
    const ground = support.background(base.intuition_base, info.draw_info, gc.gadget(o).style, intuition.style.PART_MAIN);
    support.fill(gb, r.rast_port, area, ground);
    const grid = gridFor(have.count, area.width, area.height) orelse return;
    var index: u32 = 0;
    while (index < grid.shown) : (index += 1) drawBox(base, own, r.rast_port, info, grid, area, pens, ground, index);
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(gb, r.rast_port, b, info.block_pen);
}

/// The pick moved to `index`: the old box and the new drawn again.
fn pick(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo, index: u32) void {
    if (index == own.color) return;
    const was = own.color;
    own.color = index;
    const info = gi orelse return;
    const ib = base.intuition_base;
    const have = colours(own, info.draw_info);
    const pens = have.pens orelse return;
    const b = gc.boxFor(gc.gadget(o), info);
    const inside = room(base, own, .{ .width = b.width, .height = b.height }, info.draw_info);
    const area = gc.Box{ .left = b.left + inside.left, .top = b.top + inside.top, .width = inside.width, .height = inside.height };
    const grid = gridFor(have.count, area.width, area.height) orelse return;
    const rp = ib.ObtainGIRPort(gi) orelse return;
    defer ib.ReleaseGIRPort(rp);
    const saved = support.Saved.of(base.graphics_base, rp);
    defer saved.restore(base.graphics_base, rp);
    const ground = support.background(ib, info.draw_info, gc.gadget(o).style, intuition.style.PART_MAIN);
    if (was < grid.shown) drawBox(base, own, rp, info, grid, area, pens, ground, was);
    if (index < grid.shown) drawBox(base, own, rp, info, grid, area, pens, ground, index);
}

/// The box under the pointer, in the gadget's box; null with no grid.
fn boxUnder(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo, x: i32, y: i32) ?u32 {
    const b = gc.boxFor(gc.gadget(o), gi);
    const dri: ?*intuition.DrawInfo = if (gi) |info| info.draw_info else null;
    const have = colours(own, dri);
    const area = room(base, own, .{ .width = b.width, .height = b.height }, dri);
    const grid = gridFor(have.count, area.width, area.height) orelse return null;
    return boxAt(grid, area, x, y);
}

fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = pa.PALETTE_Color, .data = own.color },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            pa.PALETTE_ColorTable => {
                own.table = @ptrFromInt(item.data);
                changed = true;
            },
            pa.PALETTE_NumColors => {
                own.num_colors = @truncate(item.data);
                changed = true;
            },
            pa.PALETTE_Color => {
                own.color = @truncate(item.data);
                changed = true;
            },
            else => {},
        }
    }
    return changed;
}

/// The size a grid of `count` boxes of `cell` needs, laid out nearest to
/// square, in its frame.
fn sizeFor(base: *gadgets.Base, own: *const Data, count: u32, cell_w: i32, cell_h: i32, dri: ?*intuition.DrawInfo) gc.Box {
    var columns: u32 = count;
    var d: u32 = 1;
    while (d <= count) : (d += 1) {
        if (count % d == 0 and d * d >= count) {
            columns = d;
            break;
        }
    }
    const rows = if (columns > 0) count / columns else 1;
    const inset = support.frameInset(base.intuition_base, own.frame.?, dri);
    return .{
        .width = @as(i32, @intCast(columns)) * cell_w + inset.width,
        .height = @as(i32, @intCast(@max(rows, 1))) * cell_h + inset.height,
    };
}

fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const dri: ?*intuition.DrawInfo = if (gi) |info| info.draw_info else g.draw_info;
    const count = @max(colours(own, dri).count, 1);
    return switch (which) {
        gc.GDOMAIN_MINIMUM => sizeFor(base, own, count, least_width + gap_x, least_height + gap_y, dri),
        gc.GDOMAIN_NOMINAL => if (own.sized != 0)
            .{ .width = g.given_width, .height = g.given_height }
        else
            sizeFor(base, own, count, nominal_cell, nominal_cell, dri),
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
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
            _ = setAttrs(base, own, new.attr_list);
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            own.pick_frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            if (own.frame == null or own.pick_frame == null) {
                ib.DisposeObject(own.frame);
                ib.DisposeObject(own.pick_frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            const ub = base.utility_base;
            own.sized = @intFromBool(ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null);
            const size = domain(base, own, gc.gadget(obj), null, gc.GDOMAIN_NOMINAL);
            const tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (own.sized != 0) utility.TAG_DONE else gc.GA_Width, .data = @intCast(size.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            ib.DisposeObject(own.frame);
            ib.DisposeObject(own.pick_frame);
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
                pa.PALETTE_Color => get.storage.* = own.color,
                pa.PALETTE_NumColors => get.storage.* = own.num_colors,
                pa.PALETTE_ColorTable => get.storage.* = @intFromPtr(own.table),
                pa.PALETTE_Pen => {
                    const table = own.table orelse return 0;
                    if (own.color >= own.num_colors) return 0;
                    get.storage.* = table[own.color];
                },
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
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            if (in.event == null) return gc.GMR_NOREUSE;
            const own = classes.instData(Data, cl, o.?);
            own.backup = own.color;
            const index = boxUnder(base, own, o.?, in.gadget_info, in.mouse.x, in.mouse.y) orelse return gc.GMR_NOREUSE;
            pick(base, own, o.?, in.gadget_info, index);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const e = in.event orelse return gc.GMR_MEACTIVE;
            if (e.class != ie.IECLASS_NEWPOINTERPOS) return gc.GMR_MEACTIVE;
            // The right button: back as it was, and nothing to report.
            if (e.code == ie.IECODE_RBUTTON) {
                pick(base, own, o.?, in.gadget_info, own.backup);
                return gc.GMR_NOREUSE;
            }
            if (boxUnder(base, own, o.?, in.gadget_info, in.mouse.x, in.mouse.y)) |index| pick(base, own, o.?, in.gadget_info, index);
            if (e.code == ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX) {
                in.termination.* = @intCast(own.color);
                tell(base, own, o.?, in.gadget_info);
                return gc.GMR_NOREUSE | gc.GMR_VERIFY;
            }
            return gc.GMR_MEACTIVE;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
