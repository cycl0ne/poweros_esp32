// SPDX-License-Identifier: MIT
//! string.gadget: a line of text, or a whole number, to type in a ridge.
//!
//! The gadget is a ridge of frameiclass's with a strgclass gadget of its
//! own inside it, inset by what the ridge needs. The strgclass gadget is in
//! no window's list: this one places it before every message it hands on,
//! hands on the input with the pointer moved into its box, and draws it
//! after the ridge. Its `ICA_TARGET` is this gadget, which tells its own
//! target the text and the number in its own name.
//!
//! The `STRINGA_` attributes and `GA_Disabled` go to the strgclass gadget
//! when this one is made and set, and the `STRINGA_` ones are read from
//! it. How it ends is strgclass's: Return, Tab, Help, a press elsewhere;
//! the code it sets is the code of the window's `IDCMP_GADGETUP`, which
//! this gadget sends as its own (`GA_RelVerify`).
//!
//! Made with `STRINGA_LongVal` and no text, it is a number field: its
//! strgclass gadget has an edit hook of this class's that turns away any
//! character but a digit, and a sign at the start, with a flash of the
//! screen. A program's own `STRINGA_EditHook` takes its place.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const sg = intuition.sghooks;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const st = gadgets.string;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = st.STRING_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// string.gadget's part of an object.
const Data = extern struct {
    /// The line itself: a strgclass gadget of this one's own.
    inner: ?*Object = null,
    /// The ridge round it.
    frame: ?*Object = null,
    /// A number field's edit hook, handed to the strgclass gadget.
    number_hook: utility.Hook = .{},
};

/// What goes to the strgclass gadget: its own attributes, and whether it
/// may be pressed.
const handed_on = [_]utility.Tag{
    gc.STRINGA_MaxChars,      gc.STRINGA_Buffer,         gc.STRINGA_UndoBuffer,
    gc.STRINGA_WorkBuffer,    gc.STRINGA_BufferPos,      gc.STRINGA_DispPos,
    gc.STRINGA_AltKeyMap,     gc.STRINGA_Font,           gc.STRINGA_Pens,
    gc.STRINGA_ActivePens,    gc.STRINGA_EditHook,       gc.STRINGA_EditModes,
    gc.STRINGA_ReplaceMode,   gc.STRINGA_FixedFieldMode, gc.STRINGA_NoFilterMode,
    gc.STRINGA_Justification, gc.STRINGA_LongVal,        gc.STRINGA_TextVal,
    gc.STRINGA_ExitHelp,      gc.GA_Disabled,            utility.TAG_DONE,
};

fn isStringTag(tag: utility.Tag) bool {
    return tag > gc.STRINGA_Dummy and tag <= gc.STRINGA_Dummy + 0xFF;
}

/// A copy of `tags` holding only what goes to the strgclass gadget; null
/// with nothing to copy or no memory. Freed with `FreeTagItems`.
fn innerTags(base: *gadgets.Base, tags: ?[*]const TagItem) ?[*]TagItem {
    const ub = base.utility_base;
    const copy = ub.CloneTagItems(tags) orelse return null;
    _ = ub.FilterTagItems(copy, &handed_on, utility.TAGFILTER_AND);
    return copy;
}

/// A number field's edit hook: a character that goes in is a digit, or a
/// sign as the first character; anything else is turned away.
fn numberKey(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    const command: *const u32 = @ptrCast(@alignCast(message orelse return 0));
    if (command.* != sg.SGH_KEY) return 0;
    const w: *sg.SGWork = @ptrCast(@alignCast(object orelse return 0));
    if (w.edit_op != sg.EO_INSERTCHAR and w.edit_op != sg.EO_REPLACECHAR) return 1;
    const c = w.code;
    const sign = (c == '-' or c == '+') and w.buffer_pos == 1;
    if ((c >= '0' and c <= '9') or sign) return 1;
    w.actions = (w.actions & ~sg.SGA_USE) | sg.SGA_BEEP;
    w.edit_op = sg.EO_BADFORMAT;
    return 1;
}

/// Where the line sits in the gadget's box: in from the ridge.
fn innerAt(base: *gadgets.Base, own: *const Data, size: gc.Box, gi: ?*const classusr.GadgetInfo) gc.Box {
    const inset = support.frameInset(base.intuition_base, own.frame.?, if (gi) |info| info.draw_info else null);
    return .{ .left = inset.left, .top = inset.top, .width = size.width - inset.width, .height = size.height - inset.height };
}

/// The strgclass gadget put where it belongs in the gadget's box, and its
/// place there, relative to the box.
fn placeInner(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) gc.Box {
    const b = gc.boxFor(gc.gadget(o), gi);
    const at = innerAt(base, own, .{ .width = b.width, .height = b.height }, gi);
    support.place(base.intuition_base, own.inner.?, .{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height });
    return at;
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(gc.gadget(o), info);
    support.drawFrame(ib, own.frame.?, r.rast_port, b, ic.IDS_NORMAL, info.draw_info, gc.gadget(o).style);
    _ = placeInner(base, own, o, info);
    support.passMarks(o, own.inner.?);
    _ = ib.SendMessage(own.inner.?, @ptrCast(r));
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(base.graphics_base, r.rast_port, b, info.block_pen);
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
            own.number_hook.entry = &numberKey;
            const ub = base.utility_base;
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_RIDGE }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);

            // A number field: made with a number and no text.
            const number = ub.FindTagItem(gc.STRINGA_LongVal, new.attr_list) != null and
                ub.FindTagItem(gc.STRINGA_TextVal, new.attr_list) == null and
                ub.FindTagItem(gc.STRINGA_EditHook, new.attr_list) == null;
            const passed = innerTags(base, new.attr_list);
            defer ub.FreeTagItems(passed);
            const tags = [_]TagItem{
                .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(obj) },
                .{ .tag = if (number) gc.STRINGA_EditHook else utility.TAG_IGNORE, .data = @intFromPtr(&own.number_hook) },
                .{ .tag = if (passed != null) utility.TAG_MORE else utility.TAG_DONE, .data = @intFromPtr(passed) },
                .{},
            };
            if (own.frame != null) own.inner = ib.NewObjectTagList(null, classusr.STRGCLASS, &tags);
            if (own.inner == null) {
                ib.DisposeObject(own.frame);
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            // Its own style is the inner one's too.
            support.passStyle(ib, base.utility_base, new.attr_list, own.inner.?);
            // Reported as the line is; made without a size, as big as a
            // line needs.
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            var ask = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
            _ = ib.SendMessage(obj, @ptrCast(&ask));
            const set_tags = [_]TagItem{
                .{ .tag = gc.GA_RelVerify, .data = 1 },
                .{ .tag = if (sized) utility.TAG_DONE else gc.GA_Width, .data = @intCast(ask.domain.width) },
                .{ .tag = gc.GA_Height, .data = @intCast(ask.domain.height) },
                .{},
            };
            var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &set_tags };
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
            // The line telling what it says now: told on, in this gadget's
            // name, and nothing to set.
            if (msg.method_id == classusr.OM_UPDATE and base.utility_base.FindTagItem(gc.STRINGA_TextVal, set.attr_list) != null) {
                const update: *classusr.OpUpdate = @ptrCast(@alignCast(msg));
                const ub = base.utility_base;
                const tags = [_]TagItem{
                    .{ .tag = gc.STRINGA_TextVal, .data = ub.GetTagData(gc.STRINGA_TextVal, 0, set.attr_list) },
                    .{ .tag = gc.STRINGA_LongVal, .data = ub.GetTagData(gc.STRINGA_LongVal, 0, set.attr_list) },
                    .{ .tag = gc.GA_ID, .data = gc.gadget(o.?).id },
                    .{},
                };
                support.notify(ib, o.?, update.gadget_info, &tags, update.flags);
                return 0;
            }
            var changed = ib.SendSuperMessage(cl, o, msg);
            if (innerTags(base, set.attr_list)) |passed| {
                defer base.utility_base.FreeTagItems(passed);
                if (passed[0].tag != utility.TAG_DONE and ib.SetAttrsTagList(own.inner, passed) != 0) changed = 1;
            }
            if (changed != 0 and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                support.redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (isStringTag(get.attr_id)) return ib.GetAttr(get.attr_id, classes.instData(Data, cl, o.?).inner, get.storage);
            return ib.SendSuperMessage(cl, o, msg);
        },
        // The line's own size, and the ridge round it.
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            var inner_ask = gc.GpDomain{ .gadget_info = ask.gadget_info, .which = ask.which };
            _ = ib.SendMessage(own.inner.?, @ptrCast(&inner_ask));
            const inset = support.frameInset(ib, own.frame.?, if (ask.gadget_info) |info| info.draw_info else null);
            const g = gc.gadget(o.?);
            var width = if (inner_ask.domain.width >= gc.GDOMAIN_UNLIMITED) gc.GDOMAIN_UNLIMITED else inner_ask.domain.width + inset.width;
            if (ask.which == gc.GDOMAIN_NOMINAL) width = @max(width, g.given_width);
            ask.domain = .{ .width = width, .height = inner_ask.domain.height + inset.height };
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
        // The key gives the line the keyboard, and the window activates
        // it: what is typed after that is text, not a shortcut.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            return if (gc.keyIsFor(o.?, k)) gc.GMKR_ACTIVATE else gc.GMKR_NOTHING;
        },
        gc.GM_GOACTIVE, gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const at = placeInner(base, own, o.?, in.gadget_info);
            return support.handOnInput(ib, own.inner.?, in, at);
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
