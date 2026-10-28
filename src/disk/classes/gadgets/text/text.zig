// SPDX-License-Identifier: MIT
//! text.gadget: a line that shows a text or a number.
//!
//! A gadgetclass gadget that is never pressed - `GM_HITTEST` finds
//! nothing - and draws in `GM_RENDER`: its ground in the back pen, then
//! the text, or the number written through its format with RawDoFmt, in
//! the front pen, against the left, the right or in the middle of the box,
//! and a sunk frameiclass frame round it with `TEXT_Border`. Clipped, a
//! text too wide stops at the box's edge with three dots where it stops
//! (graphics' `TextFitted`); otherwise it runs past, and what it ran over
//! is cleared the next time it is drawn. Set in a window, it is drawn
//! again at once.
//!
//! Given `TEXT_CopyText`, it keeps a copy of each text it is given, in
//! memory of its own, freed with the gadget. Given `TEXT_Font`, it draws
//! in that font and not the window's. Its width is that of what it shows
//! or of `TEXT_RoomFor`'s text, whichever is wider, measured the same
//! way.
//!
//! **Rich text** is `_runs.zig`'s: runs given (`TEXT_Runs`) or parsed from
//! markup (`TEXT_Markup`) are laid out a line at a time and drawn on each
//! line's baseline, each line placed by the justification; with
//! `TEXT_Wrap` lines from the top of the box until it is full, otherwise
//! the lines its `\n`s make, as one block in the box's middle. Clipped,
//! each line is cut at the box's edge as plain text is. A run's colour may
//! name a pen (`tx.screenPen`), which is the gadget's pen of that name
//! when it is drawn - so it follows the screen's pens and the style. Its
//! size is measured the same way on a RastPort of its own over a bitmap
//! of a pixel.

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
/// Rich text: markup into runs, runs into lines.
pub const rich = @import("_runs.zig");
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = tx.TEXT_CLASS,
    .version = 1,
    .revision = 4,
    .date = "28.10.2026",
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
    /// The font it draws in, the caller's; null for the RastPort's own.
    font: ?*graphics.TextFont = null,
    /// Rich text: the runs shown, the caller's or `parsed`'s.
    runs: ?[*]const tx.TextRun = null,
    parsed: ?*rich.Parsed = null,
    markup: u8 = 0,
    wrap: u8 = 0,
    pad2: [2]u8 = .{ 0, 0 },
    /// `TEXT_RoomFor`: the text whose width it keeps at the least, the
    /// caller's.
    room_for: ?[*:0]const u8 = null,
};

/// Markup parsed into runs of its own, what was parsed before let go.
fn takeMarkup(base: *gadgets.Base, own: *Data, text: ?[*:0]const u8) void {
    rich.free(base.sys_base, base.graphics_base, own.parsed);
    own.parsed = null;
    own.runs = null;
    const given = text orelse return;
    const name: [*:0]const u8 = if (own.font) |font| (font.node.name orelse graphics.POSPAZNAME) else graphics.POSPAZNAME;
    own.parsed = rich.parse(base.sys_base, base.graphics_base, given, name);
    if (own.parsed) |parsed| own.runs = &parsed.runs;
}

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
                if (own.markup != 0) takeMarkup(base, own, own.text);
                changed = true;
            },
            tx.TEXT_Markup => if (new) {
                own.markup = @intFromBool(item.data != 0);
            },
            tx.TEXT_Runs => {
                rich.free(base.sys_base, base.graphics_base, own.parsed);
                own.parsed = null;
                own.runs = @ptrFromInt(item.data);
                changed = true;
            },
            tx.TEXT_Wrap => {
                own.wrap = @intFromBool(item.data != 0);
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
            tx.TEXT_Font => {
                own.font = @ptrFromInt(item.data);
                changed = true;
            },
            tx.TEXT_RoomFor => {
                own.room_for = @ptrFromInt(item.data);
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
    // Markup given after the text: the text is parsed now.
    if (new and own.markup != 0 and own.parsed == null and own.runs == null) takeMarkup(base, own, own.text);
    return changed;
}

/// In a frame, the text keeps this far from its sides.
const text_margin = 3;

/// What the frame takes round the text, the text's margin included; none
/// without a frame.
fn frameRoom(base: *gadgets.Base, own: *const Data, dri: ?*intuition.DrawInfo, own_style: ?*const intuition.Style) gc.Box {
    const frame = if (own.border != 0) own.frame else null;
    const f = frame orelse return .{};
    const inset = support.frameInset(base.intuition_base, f, dri, own_style);
    return .{ .left = inset.left + text_margin, .top = inset.top, .width = inset.width + 2 * text_margin, .height = inset.height };
}

/// Where the text goes in the box: in from the frame, when it has one.
fn inside(base: *gadgets.Base, own: *const Data, b: gc.Box, dri: ?*intuition.DrawInfo, own_style: ?*const intuition.Style) gc.Box {
    const room = frameRoom(base, own, dri, own_style);
    return .{ .left = b.left + room.left, .top = b.top + room.top, .width = b.width - room.width, .height = b.height - room.height };
}

/// A box painted as the window paints its ground.
fn eraseBox(gb: anytype, rp: *graphics.RastPort, box: gc.Box) void {
    if (box.width <= 0 or box.height <= 0) return;
    const rect = graphics.Rect{ .min_x = box.left, .min_y = box.top, .max_x = box.left + box.width, .max_y = box.top + box.height };
    gb.EraseRect(rp, &rect);
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const rp = r.rast_port;
    const own = classes.instData(Data, cl, o);
    const b = gc.boxFor(gc.gadget(o), info);
    const styled = support.pensFor(ib, info.draw_info, gc.gadget(o).style, sdk.intuition.style.PART_MAIN, null);
    const pens: [*]const graphics.Pen = &styled;
    const front = if (own.has_front != 0) own.front else pens[sc.TEXTPEN];
    const back = if (own.has_back != 0) own.back else pens[sc.BACKGROUNDPEN];
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    // Its own font, and the RastPort's back after.
    var was_font: usize = 0;
    if (own.font) |font| {
        const ask_font = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&was_font) }, .{} };
        gb.GetRPAttrs(rp, &ask_font);
        graphics.SetFont(gb, rp, font);
    }
    defer if (own.font != null) {
        const put_font = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = was_font }, .{} };
        gb.SetRPAttrs(rp, &put_font);
    };

    const area = inside(base, own, b, info.draw_info, gc.gadget(o).style);
    // The ground, and whatever the last text left past the box: its own
    // back pen, a framed box's background, or else the window's ground as
    // the window paints it - a text on its own is written on the window.
    const plain = own.has_back == 0 and own.border == 0;
    const past = gc.Box{ .left = b.left + b.width, .top = area.top, .width = own.overrun, .height = area.height };
    if (plain) {
        eraseBox(gb, rp, area);
        if (own.overrun > 0) eraseBox(gb, rp, past);
    } else {
        support.fill(gb, rp, area, back);
        if (own.overrun > 0) support.fill(gb, rp, past, back);
    }
    own.overrun = 0;
    if (own.border != 0) if (own.frame) |frame| support.drawGadgetFrame(ib, o, frame, rp, b, ic.IDS_NORMAL, info.draw_info, sdk.intuition.style.PART_MAIN);

    if (own.runs) |runs| {
        const right = drawRuns(base, own, rp, runs, area, front, &styled);
        own.overrun = @max(right - (b.left + b.width), 0);
        return ghostIfDisabled(base, o, rp, b, info);
    }
    const text = shown(base, own) orelse return;
    const count: u32 = @intCast(textLen(text));
    const width = gb.TextLength(rp, text, count);
    // Too wide and clipped: as much as fits from the left, and the dots.
    const cut = own.clipped != 0 and width > area.width;
    var line: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&line) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    const left = if (cut) area.left else switch (own.justification) {
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
    if (cut) {
        _ = gb.TextFitted(rp, text, count, @max(area.width, 0));
    } else {
        gb.Text(rp, text, count);
        own.overrun = @max(left + width - (b.left + b.width), 0);
    }
    ghostIfDisabled(base, o, rp, b, info);
}

/// The font a RastPort has now.
fn fontOf(gb: anytype, rp: *graphics.RastPort) ?*graphics.TextFont {
    var font: usize = 0;
    gb.GetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(&font) }, .{} });
    return @ptrFromInt(font);
}

/// Where a line goes across `area` by the justification.
fn lineLeft(own: *const Data, area: gc.Box, width: i32) i32 {
    return switch (own.justification) {
        tx.TEXT_JUSTIFY_RIGHT => area.left + area.width - width,
        tx.TEXT_JUSTIFY_CENTER => area.left + @divTrunc(area.width - width, 2),
        else => area.left,
    };
}

/// The ghost over a disabled gadget's box.
fn ghostIfDisabled(base: *gadgets.Base, o: *Object, rp: *graphics.RastPort, b: gc.Box, info: *classusr.GadgetInfo) void {
    if (gc.gadget(o).flags & gc.GFLG_DISABLED != 0) support.ghost(base.graphics_base, rp, b, info.block_pen);
}

/// Rich text in `area`: wrapped lines from its top while they fit, or the
/// lines its line breaks make as one block in its middle - each cut at
/// the area's edge when it is clipped. How far right the lines reached.
fn drawRuns(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, runs: [*]const tx.TextRun, area: gc.Box, front: graphics.Pen, pens: *const [sc.NUMDRIPENS]graphics.Pen) i32 {
    const gb = base.graphics_base;
    const ink = rich.Ink{ .gb = gb, .rp = rp, .font = fontOf(gb, rp) orelse return area.left, .front = front, .pens = pens };
    const wrap = own.wrap != 0;
    const limit: ?i32 = if (own.clipped != 0) area.left + area.width else null;
    var top = area.top;
    if (!wrap) top += @max(@divTrunc(area.height - blockHeight(ink, runs, area.width), 2), 0);
    var right = area.left;
    var pos = rich.Pos{};
    while (rich.lineAt(ink, runs, pos, area.width, wrap)) |line| {
        if (top + line.height > area.top + area.height and !(top == area.top)) break;
        const width = if (limit != null) @min(line.width, area.width) else line.width;
        right = @max(right, rich.drawLine(ink, runs, line, lineLeft(own, area, width), top, limit));
        top += line.height;
        if (line.end.run == pos.run and line.end.at == pos.at) break;
        pos = line.end;
    }
    return right;
}

/// How tall the lines of `runs` are together, laid out in `width`.
fn blockHeight(ink: rich.Ink, runs: [*]const tx.TextRun, width: i32) i32 {
    var height: i32 = 0;
    var pos = rich.Pos{};
    while (rich.lineAt(ink, runs, pos, width, false)) |line| {
        height += line.height;
        if (line.end.run == pos.run and line.end.at == pos.at) break;
        pos = line.end;
    }
    return height;
}

/// Rich text's size: its lines in `width` (or one line), measured on a
/// RastPort of its own in the gadget's font.
fn measureRuns(base: *gadgets.Base, own: *const Data, runs: [*]const tx.TextRun, font: ?*graphics.TextFont, width: i32) gc.Box {
    const gb = base.graphics_base;
    const pixel = gb.AllocBitMapTagList(&[_]TagItem{
        .{ .tag = graphics.BMTAG_Width, .data = 1 },
        .{ .tag = graphics.BMTAG_Height, .data = 1 },
        .{},
    }) orelse return .{};
    defer gb.FreeBitMap(pixel);
    const rp = gb.CreateRastPortTagList(&[_]TagItem{ .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(pixel) }, .{} }) orelse return .{};
    defer gb.FreeRastPort(rp);
    if (font) |f| graphics.SetFont(gb, rp, f);
    // No font to measure in anywhere: the system's own.
    const opened = if (fontOf(gb, rp) == null) gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }) else null;
    defer gb.CloseFont(opened);
    if (opened) |f| graphics.SetFont(gb, rp, f);
    const ink = rich.Ink{ .gb = gb, .rp = rp, .font = fontOf(gb, rp) orelse return .{}, .front = 0 };
    const wrap = own.wrap != 0;
    var pos = rich.Pos{};
    var box = gc.Box{};
    while (rich.lineAt(ink, runs, pos, width, wrap)) |line| {
        box.width = @max(box.width, line.width);
        box.height += line.height;
        if (line.end.run == pos.run and line.end.at == pos.at) break;
        pos = line.end;
    }
    return box;
}

/// Its size: a line of the font, the text's width, and the frame.
/// How wide `text` is in the gadget's font: measured in the window's, a
/// character each in a font of its own.
fn widthOf(base: *gadgets.Base, own: *const Data, measure: support.Measure, text: [*:0]const u8) i32 {
    if (own.font) |font| return @intCast(textLen(text) * font.image.x_size);
    return measure.width(base.intuition_base, text);
}

fn domain(base: *gadgets.Base, own: *Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    // The room `TEXT_RoomFor` keeps, whatever is shown.
    const kept: i32 = if (own.room_for) |text| widthOf(base, own, measure, text) else 0;
    var box = gc.Box{ .width = if (shown(base, own)) |text| measure.width(ib, text) else 0, .height = measure.lineHeight(base.graphics_base) };
    if (own.runs) |runs| {
        const room = frameRoom(base, own, if (gi) |info| info.draw_info else g.draw_info, g.style);
        const measured = measureRuns(base, own, runs, own.font orelse measure.font, if (own.wrap != 0) g.given_width - room.width else 0x7FFF);
        const lines = gc.Box{ .width = @max(measured.width, kept) + room.width, .height = @max(measured.height, 1) + room.height };
        return switch (which) {
            gc.GDOMAIN_MINIMUM => .{ .width = if (own.wrap != 0 or own.clipped != 0) 0 else lines.width, .height = lines.height },
            gc.GDOMAIN_NOMINAL => .{ .width = @max(lines.width, g.given_width), .height = lines.height },
            else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = lines.height },
        };
    }
    // In a font of its own: a line of that font, and its nominal width a
    // character.
    if (own.font) |font| {
        box.height = font.image.height;
        if (shown(base, own)) |text| box.width = @intCast(textLen(text) * font.image.x_size);
    }
    box.width = @max(box.width, kept);
    const room = frameRoom(base, own, if (gi) |info| info.draw_info else g.draw_info, g.style);
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
            rich.free(base.sys_base, base.graphics_base, own.parsed);
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
