// SPDX-License-Identifier: MIT
//! text.gadget: a line that shows a text or a number.
//!
//! A gadgetclass gadget that is never pressed - `GM_HITTEST` finds
//! nothing - and draws in `GM_RENDER`: its ground in the back pen, then
//! the text, or the number written through its format with RawDoFmt, in
//! the front pen, against the left, the right or in the middle of the box,
//! and a sunk frameiclass frame round it with `TEXT_Border`. Clipped, the
//! text stops at the box's edge; otherwise it runs past, and what it ran
//! over is cleared the next time it is drawn. Set in a window, it is drawn
//! again at once.
//!
//! Given `TEXT_CopyText`, it keeps a copy of each text it is given, in
//! memory of its own, freed with the gadget.

const sdk = @import("sdk");
const exec = sdk.exec;
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
const tx = gadgets.text;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = tx.TEXT_CLASS,
    .version = 1,
    .date = "25.09.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// text.gadget's part of an object.
const Data = extern struct {
    /// What it shows: the text, or the number through the format.
    text: ?[*:0]const u8 = null,
    number: i32 = 0,
    shows_number: u8 = 0,
    /// It copies its texts, and `text` is its own copy.
    copies: u8 = 0,
    owns_text: u8 = 0,
    border: u8 = 0,
    clipped: u8 = 0,
    has_front: u8 = 0,
    has_back: u8 = 0,
    pad: u8 = 0,
    format: ?[*:0]const u8 = null,
    justification: u32 = tx.TEXT_JUSTIFY_LEFT,
    front: graphics.Pen = 0,
    back: graphics.Pen = 0,
    /// The sunk frame, while it has one.
    frame: ?*Object = null,
    /// How far the text last ran past the box to the right, to be cleared.
    overrun: i32 = 0,
    /// The number as text.
    written: [40]u8 = @splat(0),
};

fn textLen(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}

/// A text taken: copied into memory of its own when it copies, the old
/// copy given back.
fn takeText(base: *gadgets.Base, own: *Data, text: ?[*:0]const u8) void {
    const sys = base.sys_base;
    if (own.owns_text != 0) sys.FreeVec(@ptrCast(@constCast(own.text)));
    own.owns_text = 0;
    own.text = text;
    own.shows_number = 0;
    const from = text orelse return;
    if (own.copies == 0) return;
    const len = textLen(from);
    const copy: [*]u8 = @ptrCast(sys.AllocVec(len + 1, exec.MEMF_ANY) orelse {
        own.text = null;
        return;
    });
    @memcpy(copy[0..len], from[0..len]);
    copy[len] = 0;
    own.text = @ptrCast(copy);
    own.owns_text = 1;
}

/// What it shows now.
fn shown(base: *gadgets.Base, own: *Data) ?[*:0]const u8 {
    if (own.shows_number == 0) return own.text;
    return support.formatNumber(base.sys_base, own.format orelse "%ld", own.number, &own.written);
}

/// The attributes among `tags`: whether anything that shows changed.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem, new: bool) bool {
    const ub = base.utility_base;
    const ib = base.intuition_base;
    var changed = false;
    var state = tags;
    while (ub.NextTagItem(&state)) |item| {
        switch (item.tag) {
            tx.TEXT_CopyText => if (new) {
                own.copies = @intFromBool(item.data != 0);
            },
            tx.TEXT_Text => {
                takeText(base, own, @ptrFromInt(item.data));
                changed = true;
            },
            tx.TEXT_Number => {
                own.number = @truncate(@as(isize, @bitCast(item.data)));
                own.shows_number = 1;
                changed = true;
            },
            tx.TEXT_Format => {
                own.format = @ptrFromInt(item.data);
                changed = true;
            },
            tx.TEXT_Border => {
                own.border = @intFromBool(item.data != 0);
                if (own.border != 0 and own.frame == null) {
                    const frame_tags = [_]TagItem{
                        .{ .tag = ic.IA_FrameType, .data = ic.FRAME_BUTTON },
                        .{ .tag = ic.IA_Recessed, .data = 1 },
                        .{},
                    };
                    own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
                }
                changed = true;
            },
            tx.TEXT_Justification => {
                own.justification = @truncate(item.data);
                changed = true;
            },
            tx.TEXT_Clipped => {
                own.clipped = @intFromBool(item.data != 0);
                changed = true;
            },
            tx.TEXT_FrontPen => {
                own.front = @truncate(item.data);
                own.has_front = 1;
                changed = true;
            },
            tx.TEXT_BackPen => {
                own.back = @truncate(item.data);
                own.has_back = 1;
                changed = true;
            },
            else => {},
        }
    }
    // CopyText given with the text: the text was taken before it was
    // known to copy, so it is taken again.
    if (new and own.copies != 0 and own.owns_text == 0 and own.shows_number == 0) {
        if (own.text) |text| takeText(base, own, text);
    }
    return changed;
}

/// In a frame, the text keeps this far from its sides.
const text_margin = 3;

/// What the frame takes round the text, the text's margin included; none
/// without a frame.
fn frameRoom(base: *gadgets.Base, own: *const Data, dri: ?*intuition.DrawInfo) gc.Box {
    const frame = if (own.border != 0) own.frame else null;
    const f = frame orelse return .{};
    const inset = support.frameInset(base.intuition_base, f, dri);
    return .{ .left = inset.left + text_margin, .top = inset.top, .width = inset.width + 2 * text_margin, .height = inset.height };
}

/// Where the text goes in the box: in from the frame, when it has one.
fn inside(base: *gadgets.Base, own: *const Data, b: gc.Box, dri: ?*intuition.DrawInfo) gc.Box {
    const room = frameRoom(base, own, dri);
    return .{ .left = b.left + room.left, .top = b.top + room.top, .width = b.width - room.width, .height = b.height - room.height };
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(gc.gadget(o), info);
    const pens = info.draw_info.pens;
    const front = if (own.has_front != 0) own.front else pens[sc.TEXTPEN];
    const back = if (own.has_back != 0) own.back else pens[sc.BACKGROUNDPEN];
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);

    const area = inside(base, own, b, info.draw_info);
    // The ground, and whatever the last text left past the box.
    support.fill(gb, rp, area, back);
    if (own.overrun > 0) support.fill(gb, rp, .{ .left = b.left + b.width, .top = area.top, .width = own.overrun, .height = area.height }, back);
    own.overrun = 0;
    if (own.border != 0) if (own.frame) |frame| support.drawFrame(ib, frame, rp, b, ic.IDS_NORMAL, info.draw_info);

    const text = shown(base, own) orelse return;
    var count: u32 = @intCast(textLen(text));
    var width = gb.TextLength(rp, text, count);
    if (own.clipped != 0 and width > area.width) {
        var extent: graphics.TextExtent = .{};
        count = gb.TextFit(rp, text, count, &extent, null, 1, @max(area.width, 0), 0);
        width = gb.TextLength(rp, text, count);
    }
    var line: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    const left = switch (own.justification) {
        tx.TEXT_JUSTIFY_RIGHT => area.left + area.width - width,
        tx.TEXT_JUSTIFY_CENTER => area.left + @divTrunc(area.width - width, 2),
        else => area.left,
    };
    const top = area.top + @divTrunc(area.height - @as(i32, @intCast(line)), 2);
    var baseline: u32 = 0;
    const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} };
    gb.GetRPAttrs(rp, &metric);
    support.setPen(gb, rp, front);
    const mode = [_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} };
    gb.SetRPAttrs(rp, &mode);
    gb.Move(rp, left, top + @as(i32, @intCast(baseline)));
    gb.Text(rp, text, count);
    own.overrun = @max(left + width - (b.left + b.width), 0);
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// Its size: a line of the font, the text's width, and the frame.
fn domain(base: *gadgets.Base, own: *Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    var box = gc.Box{ .width = if (shown(base, own)) |text| measure.width(ib, text) else 0, .height = measure.lineHeight(base.graphics_base) };
    const room = frameRoom(base, own, if (gi) |info| info.draw_info else g.draw_info);
    box.width += room.width;
    box.height += room.height;
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = if (own.clipped != 0) 0 else box.width, .height = box.height },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(box.width, g.given_width), .height = box.height },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = box.height },
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
            if (own.owns_text != 0) base.sys_base.FreeVec(@ptrCast(@constCast(own.text)));
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
                tx.TEXT_Text => get.storage.* = @intFromPtr(own.text),
                tx.TEXT_Number => get.storage.* = @bitCast(@as(isize, own.number)),
                else => return ib.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        // Never pressed.
        gc.GM_HITTEST => return 0,
        gc.GM_GOACTIVE => return gc.GMR_NOREUSE,
        gc.GM_RENDER => {
            render(base, cl, o.?, @ptrCast(@alignCast(msg)));
            return 0;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
