// SPDX-License-Identifier: MIT
//! checkbox.gadget: a box that is ticked or not.
//!
//! It is a buttongclass that turns over on a press (`GA_ToggleSelect`)
//! and reports when let go over it (`GA_RelVerify`): buttongclass does the
//! pressing, and this class adds the rest. The ticked state is the
//! gadget's `GFLG_SELECTED`, shown by sysiclass's `CHECKIMAGE` in the
//! selected state. A press tells the target `CHECKBOX_Checked` and the
//! gadget's `GA_ID`; let go over the box, the new state is the code of
//! the window's `IDCMP_GADGETUP`.
//!
//! The box is sized to the font - a line of it and three pixels high, as
//! wide as the image's own proportions make that - and is drawn at the
//! gadget's left, in the middle of its height, however much room a layout
//! gives it. Only the box is pressed. Disabled, the ghost goes over the
//! box.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const sc = intuition.screens;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const cb = gadgets.checkbox;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = cb.CHECKBOX_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.BUTTONGCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// checkbox.gadget's part of an object.
const Data = extern struct {
    /// The box: sysiclass's CHECKIMAGE, at the size of `mark`.
    image: ?*Object = null,
    mark: gc.Box = .{},
    /// `CHECKBOX_Scaled`: the box fills the room it is given.
    scaled: u8 = 0,
    pad: [3]u8 = @splat(0),
};

/// The box for a font whose lines are `line` high: three pixels more, and
/// the image's 26 by 11 kept.
fn markSize(line: i32) gc.Box {
    const height = line + 3;
    return .{ .width = @divTrunc(26 * height + 5, 11), .height = height };
}

/// The box as big as the room allows, keeping its shape: as tall as the
/// room and no wider than it.
fn markScaled(room: gc.Box) gc.Box {
    const by_width = @divTrunc(11 * room.width - 5, 26);
    const height = @max(@min(room.height, by_width), 1);
    return .{ .width = @divTrunc(26 * height + 5, 11), .height = height };
}

/// The box's size: a line of the font, or the room the gadget was given
/// when it is a scaled one. `room` is false where the answer decides how
/// much room there is - `GM_DOMAIN` - so that the two cannot chase each
/// other.
fn markFor(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, room: bool) gc.Box {
    const measure = support.Measure.of(base.intuition_base, g, gi);
    defer measure.done(base.intuition_base);
    const by_font = markSize(measure.lineHeight(base.graphics_base));
    if (!room or own.scaled == 0) return by_font;
    const fitted = markScaled(gc.boxFor(g, gi));
    return if (fitted.height > by_font.height) fitted else by_font;
}

/// Where the box is drawn in the gadget's box: at its left, in the middle
/// of its height.
fn markIn(own: *const Data, b: gc.Box) gc.Box {
    return .{
        .left = b.left,
        .top = b.top + @divTrunc(b.height - own.mark.height, 2),
        .width = own.mark.width,
        .height = own.mark.height,
    };
}

/// The image at the size of the box for this font, made again when that
/// has changed.
fn fitImage(base: *gadgets.Base, own: *Data, mark: gc.Box) void {
    if (own.image != null and mark.width == own.mark.width and mark.height == own.mark.height) return;
    const size = [_]TagItem{
        .{ .tag = ic.IA_Width, .data = @intCast(mark.width) },
        .{ .tag = ic.IA_Height, .data = @intCast(mark.height) },
        .{},
    };
    if (own.image) |image| {
        _ = base.intuition_base.SetAttrsTagList(image, &size);
    } else {
        const tags = [_]TagItem{
            .{ .tag = ic.SYSIA_Which, .data = ic.CHECKIMAGE },
            .{ .tag = utility.TAG_MORE, .data = @intFromPtr(&size) },
        };
        own.image = base.intuition_base.NewObjectTagList(null, classusr.SYSICLASS, &tags);
    }
    own.mark = mark;
}

fn checked(g: *const gc.Gadget) bool {
    return g.flags & gc.GFLG_SELECTED != 0;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *sdk.graphics.RastPort) void {
    const info = gi orelse return;
    const g = gc.gadget(o);
    const own = classes.instData(Data, cl, o);
    fitImage(base, own, markFor(base, own, g, gi, true));
    const image = own.image orelse return;
    const gb = base.graphics_base;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const at = markIn(own, gc.boxFor(g, gi));
    const state = if (checked(g)) ic.IDS_SELECTED else ic.IDS_NORMAL;
    support.drawImage(base.intuition_base, image, rp, at.left, at.top, state, info.draw_info, g.style);
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, at, info.block_pen);
}

/// The target told the state, and which gadget it is.
fn tell(base: *gadgets.Base, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const g = gc.gadget(o);
    const tags = [_]TagItem{
        .{ .tag = cb.CHECKBOX_Checked, .data = @intFromBool(checked(g)) },
        .{ .tag = gc.GA_ID, .data = g.id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

/// `CHECKBOX_Checked` among `tags`: the gadget's selected state. True when
/// it was there.
fn setChecked(base: *gadgets.Base, o: *Object, tags: ?[*]const TagItem) bool {
    const item = base.utility_base.FindTagItem(cb.CHECKBOX_Checked, tags) orelse return false;
    const g = gc.gadget(o);
    if (item.data != 0) g.flags |= gc.GFLG_SELECTED else g.flags &= ~gc.GFLG_SELECTED;
    return true;
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
            const g = gc.gadget(obj);
            own.scaled = @intFromBool(base.utility_base.GetTagData(cb.CHECKBOX_Scaled, 0, new.attr_list) != 0);
            _ = setChecked(base, obj, new.attr_list);
            fitImage(base, own, markFor(base, own, g, null, false));
            if (own.image == null) {
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Turned over by a press, reported when let go over it; made
            // without a size, the box's size.
            const ub = base.utility_base;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            const tags = [_]TagItem{
                .{ .tag = gc.GA_ToggleSelect, .data = 1 },
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (sized) utility.TAG_DONE else gc.GA_Width, .data = @intCast(own.mark.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(own.mark.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
            _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            return made;
        },
        classusr.OM_DISPOSE => {
            ib.DisposeObject(classes.instData(Data, cl, o orelse return 0).image);
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (setChecked(base, o.?, set.attr_list)) changed = 1;
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (get.attr_id == cb.CHECKBOX_Checked) {
                get.storage.* = @intFromBool(checked(gc.gadget(o.?)));
                return 1;
            }
            return ib.SendSuperMessage(cl, o, msg);
        },
        // The box, at the least and as it looks right; as much room as
        // there is at the most, which it leaves empty.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const mark = markFor(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, false);
            ask.domain = if (ask.which == gc.GDOMAIN_MAXIMUM)
                .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED }
            else
                .{ .width = mark.width, .height = mark.height };
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const g = gc.gadget(o.?);
            const own = classes.instData(Data, cl, o.?);
            const b = gc.boxFor(g, ht.gadget_info);
            fitImage(base, own, markFor(base, own, g, ht.gadget_info, true));
            const at = markIn(own, .{ .width = b.width, .height = b.height });
            const x = ht.mouse.x;
            const y = ht.mouse.y;
            const hit = x >= at.left and y >= at.top and x < at.left + at.width and y < at.top + at.height;
            return if (hit) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            render(base, cl, o.?, r.gadget_info, r.rast_port);
            return 0;
        },
        // buttongclass turns it over and draws it; the target hears the
        // new state.
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const result = ib.SendSuperMessage(cl, o, msg);
            if (in.event != null) tell(base, o.?, in.gadget_info);
            return result;
        },
        // The key turns it over, as a press does, and the state is the
        // code: the superclass does the turning over and the drawing.
        gc.GM_KEY => {
            const result = ib.SendSuperMessage(cl, o, msg);
            if (result & gc.GMKR_VERIFY != 0) {
                const k: *gc.GpKey = @ptrCast(@alignCast(msg));
                k.termination.* = @intFromBool(checked(gc.gadget(o.?)));
                tell(base, o.?, k.gadget_info);
            }
            return result;
        },
        // Let go over the box: the state is the code.
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const result = ib.SendSuperMessage(cl, o, msg);
            if (result & gc.GMR_VERIFY != 0) in.termination.* = @intFromBool(checked(gc.gadget(o.?)));
            return result;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
