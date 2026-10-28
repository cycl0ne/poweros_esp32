// SPDX-License-Identifier: MIT
//! chooser.gadget: a button that pops up a list to pick from.
//!
//! The button is a frameiclass button frame with the label it shows in it
//! and a mark - a triangle pointing down - at its right end, drawn as a
//! cycle gadget is. What makes it a chooser is the panel, a layer over the
//! screen under the button that lists the labels (`sdk.gadgets.listpanel`):
//! pressed and dragged, the label let go over is taken; let go over the
//! button, the panel stays up for a press on a label - or anywhere else,
//! which takes nothing. The panel's edge is the button's frame.

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
const listpanel = gadgets.listpanel;
const ch = gadgets.chooser;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const LayersBase = sdk.interface.layers.LayersBase;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = ch.CHOOSER_CLASS,
    .version = 1,
    .revision = 1,
    .date = "28.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    // The panel is a layer of its own on the screen.
    .opens = &.{"layers.library"},
});
comptime {
    _ = Library;
}

/// Room either side of a label, in the button as in the panel.
const text_margin = listpanel.text_margin;
/// How wide the mark's box is beside the button's text.
const mark_width = 12;

/// chooser.gadget's part of an object.
pub const Data = extern struct {
    labels: ?[*]const ?[*:0]const u8 = null,
    count: u32 = 0,
    active: u32 = 0,
    /// `CHOOSER_MaxPanelLines`: 0 for as many as there are.
    max_lines: u32 = 0,
    /// The button's frame, which the panel's edge is drawn with too.
    frame: ?*Object = null,
    /// The panel, while it is up.
    panel: listpanel.Panel = .{},
};

fn layersOf(base: *gadgets.Base) *LayersBase {
    return @ptrCast(base.opened[0].?);
}

/// The attributes among `tags`: whether what the button shows changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            ch.CHOOSER_Labels => {
                const labels: ?[*]const ?[*:0]const u8 = @ptrFromInt(item.data);
                own.labels = labels;
                own.count = 0;
                if (labels) |list| while (list[own.count] != null) {
                    own.count += 1;
                };
                changed = true;
            },
            ch.CHOOSER_Active => {
                own.active = @truncate(item.data);
                changed = true;
            },
            ch.CHOOSER_MaxPanelLines => own.max_lines = @truncate(item.data),
            else => {},
        }
    }
    if (own.count == 0) own.active = 0 else if (own.active >= own.count) own.active = own.count - 1;
    return changed;
}

fn labelAt(own: *const Data, which: u32) ?[*:0]const u8 {
    if (which >= own.count) return null;
    return own.labels.?[which];
}

/// The target told which label is shown.
fn tell(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const tags = [_]TagItem{
        .{ .tag = ch.CHOOSER_Active, .data = own.active },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

// --- the button -------------------------------------------------------------

/// The button's size for its font: its frame round the widest label and
/// the mark.
fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    var widest: i32 = 0;
    for (0..own.count) |i| widest = @max(widest, measure.width(ib, own.labels.?[i].?));
    const line = measure.lineHeight(base.graphics_base);
    measure.done(ib);
    const dri = if (gi) |info| info.draw_info else g.draw_info;
    const inset = if (own.frame) |frame| support.frameInset(ib, frame, dri, g.style) else gc.Box{ .left = 2, .top = 2, .width = 4, .height = 4 };
    const box = gc.Box{
        .width = widest + 2 * text_margin + mark_width + inset.width,
        .height = line + inset.height,
    };
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = 2 * text_margin + mark_width + inset.width, .height = box.height },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(box.width, g.given_width), .height = box.height },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = box.height },
    };
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const g = gc.gadget(o);
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(g, info);
    const styled = support.pensFor(ib, info.draw_info, g.style, sdk.intuition.style.PART_MAIN, null);
    const pens: [*]const graphics.Pen = &styled;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    const pressed = own.panel.isUp();
    if (own.frame) |frame| support.drawGadgetFrame(ib, o, frame, rp, b, if (pressed) ic.IDS_SELECTED else ic.IDS_NORMAL, info.draw_info, sdk.intuition.style.PART_MAIN);
    const inset = if (own.frame) |frame| support.frameInset(ib, frame, info.draw_info, gc.gadget(o).style) else gc.Box{ .left = 2, .top = 2, .width = 4, .height = 4 };
    const inner = gc.Box{
        .left = b.left + inset.left,
        .top = b.top + inset.top,
        .width = b.width - inset.width,
        .height = b.height - inset.height,
    };
    const ink = if (pressed) pens[sc.FILLTEXTPEN] else pens[sc.TEXTPEN];
    support.fill(gb, rp, inner, if (pressed) pens[sc.FILLPEN] else pens[sc.BACKGROUNDPEN]);
    // The mark: a triangle pointing down, in a square at the right end.
    support.setPen(gb, rp, ink);
    support.drawArrow(ib, gb, null, rp, info.draw_info, .{
        .at = .{ .left = inner.left + inner.width - mark_width, .top = inner.top, .width = mark_width, .height = inner.height },
        .vertical = true,
        .forward = true,
    });
    if (labelAt(own, own.active)) |text| {
        var count = support.textLen(text);
        const room = inner.width - mark_width - 2 * text_margin;
        if (gb.TextLength(rp, text, count) > room) {
            var extent: graphics.TextExtent = .{};
            count = gb.TextFit(rp, text, count, &extent, null, 1, @max(room, 0), 0);
        }
        var line: u32 = 0;
        var baseline: u32 = 0;
        const ask = [_]TagItem{
            .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) },
            .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
            .{},
        };
        gb.GetRPAttrs(rp, &ask);
        const tags = [_]TagItem{
            .{ .tag = graphics.RPTAG_APen, .data = ink },
            .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
            .{},
        };
        gb.SetRPAttrs(rp, &tags);
        const top = inner.top + @divTrunc(inner.height - @as(i32, @intCast(line)), 2);
        gb.Move(rp, inner.left + text_margin, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, text, count);
    }
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

// --- the panel --------------------------------------------------------------

/// The label under the pointer when the pick is over taken: the one the
/// gadget shows from now on, reported to the window and told to the
/// target.
fn take(base: *gadgets.Base, own: *Data, o: *Object, info: *classusr.GadgetInfo, termination: *i32) usize {
    const picked = own.panel.hot;
    own.panel.close(layersOf(base));
    if (picked != listpanel.NONE) own.active = picked;
    support.redraw(base.intuition_base, o, info);
    if (picked == listpanel.NONE) return gc.GMR_NOREUSE;
    termination.* = @intCast(picked);
    tell(base, own, o, info);
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
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON }, .{} };
            own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            _ = setAttrs(base, own, new.attr_list);
            // Reported when a label is taken; made without a size, as big
            // as it looks right.
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
            own.panel.close(layersOf(base));
            ib.DisposeObject(own.frame);
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
                ch.CHOOSER_Active => get.storage.* = own.active,
                ch.CHOOSER_NumLabels => get.storage.* = own.count,
                ch.CHOOSER_Labels => get.storage.* = @intFromPtr(own.labels),
                ch.CHOOSER_MaxPanelLines => get.storage.* = own.max_lines,
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
        // The key takes the next label, the one before with a Shift key
        // held, without opening the panel: the panel is the pointer's way
        // in, and a key has no pointer.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            const own = classes.instData(Data, cl, o.?);
            if (own.count == 0) return gc.GMKR_DONE;
            const shift = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;
            own.active = if (k.qualifier & shift != 0)
                (if (own.active == 0) own.count - 1 else own.active - 1)
            else
                (if (own.active + 1 >= own.count) 0 else own.active + 1);
            k.termination.* = @intCast(own.active);
            support.redraw(ib, o.?, k.gadget_info);
            tell(base, own, o.?, k.gadget_info);
            return gc.GMKR_VERIFY;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const info = in.gadget_info orelse return gc.GMR_NOREUSE;
            if (in.event == null or own.count == 0) return gc.GMR_NOREUSE;
            if (!own.panel.open(base, layersOf(base), own.frame, o.?, info, own.labels, own.count, own.max_lines, own.active)) return gc.GMR_NOREUSE;
            // Pressed: the button is drawn pressed while the panel is up.
            support.redraw(ib, o.?, info);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const info = in.gadget_info orelse return gc.GMR_NOREUSE;
            if (!own.panel.isUp()) return gc.GMR_NOREUSE;
            return switch (own.panel.input(base, layersOf(base), own.frame, o.?, info, in)) {
                .more => gc.GMR_MEACTIVE,
                .over => take(base, own, o.?, info, in.termination),
            };
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.panel.isUp()) {
                own.panel.close(layersOf(base));
                support.redraw(ib, o.?, gone.gadget_info);
            }
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
