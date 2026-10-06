// SPDX-License-Identifier: MIT
//! textedit.gadget: text of many lines, to read and to edit. What a
//! program sees is in sdk/libs/gadgets/textedit.zig; this is how it works.
//!
//! The text and its rows are text.zig's, undo is undo.zig's; this file
//! draws them, takes the keys and the pointer, and keeps the cursor, the
//! selection and the view. The gadget is a field frame of frameiclass's
//! with a scroller.gadget at its right, and one along its bottom when rows
//! do not wrap: both are its own and in no window's list, placed before
//! every message they are handed, their `ICA_TARGET` this gadget. The one
//! at the bottom tells its top as `TEXTEDIT_TopHoriz` (`ICA_MAP`), which
//! is how the two are told apart. Without them (`TEXTEDIT_Scrollers`
//! false) the field is the whole gadget, and scrollers in the window's
//! border reach the view through the same two tags.
//!
//! **What it tells** its target - the cursor's line and column, whether
//! the text changed, and the view - goes out only when one of them is
//! not what was told last (`Told`), so a scroller set from what it hears
//! and telling the gadget back ends there.
//!
//! **Positions.** The cursor and the anchor are positions in the text;
//! what lies between them is selected. A move with Shift held moves the
//! cursor alone, any other moves both. Moving up and down keeps to the
//! column the cursor was last put in by anything else (`goal_x`), so it
//! goes back there past short lines.
//!
//! **Drawing** is always the whole gadget, which intuition does aside and
//! puts on in one copy (`support.redraw`), so a change never shows half
//! made. A row is drawn in runs of bytes that share a pen, each placed
//! where the width table puts it, so the text, the cursor and the
//! selection agree to the pixel. Nothing is drawn past the field: a byte
//! that does not fit whole is left out, and a line feed or a control
//! character takes no room.
//!
//! **The keyboard** is the gadget's from a press in it, or from
//! `ActivateGadget`, until a press elsewhere. The keys a program answers -
//! right Amiga with anything, Control-C, -X and -V, the menu button - end
//! it with `GMR_REUSE`, so the event goes on to the window as though the
//! gadget had not had it.
//!
//! **Widths** come from the window's font, a byte at a time, measured once
//! for each font (`IntuiTextLength`); a tab stops every eight spaces.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const ic = intuition.imageclass;
const icc = intuition.icclass;
const pg = intuition.propgclass;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const gadgets = sdk.gadgets;
const support = gadgets.support;
const sr = gadgets.scroller;
const te = gadgets.textedit;
const KeymapBase = sdk.interface.keymap.KeymapBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const model = @import("text.zig");
const undo = @import("undo.zig");
const Text = model.Text;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = te.TEXTEDIT_CLASS,
    .version = 1,
    .date = "06.10.2026",
    .super = classusr.GADGETCLASS,
    .Instance = Data,
    .dispatch = dispatch,
    .opens = &.{ sr.SCROLLER_LIBRARY, sdk.keymap.KEYMAPNAME },
});
comptime {
    _ = Library;
}

/// Room between the frame and the text at either side.
const text_margin = 3;
const scroll_size = 16;
/// The cursor's width.
const cursor_width = 2;

/// The bottom scroller's top, as the view across.
const left_map = [_]TagItem{ .{ .tag = sr.SCROLLER_Top, .data = te.TEXTEDIT_TopHoriz }, .{} };

// The rawkeys this gadget answers itself.
const RAW_BACKSPACE = 0x41;
const RAW_TAB = 0x42;
const RAW_ENTER = 0x43;
const RAW_RETURN = 0x44;
const RAW_ESCAPE = 0x45;
const RAW_DELETE = 0x46;
const RAW_PAGEUP = 0x48;
const RAW_PAGEDOWN = 0x49;
const RAW_UP = 0x4C;
const RAW_DOWN = 0x4D;
const RAW_RIGHT = 0x4E;
const RAW_LEFT = 0x4F;
const RAW_HOME = 0x70;
const RAW_END = 0x71;

const SHIFT = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT;
const COMMAND = ie.IEQUALIFIER_LCOMMAND | ie.IEQUALIFIER_RCOMMAND;

/// Which inner gadget has the input.
const Scrolling = enum(u8) { none, vertical, horizontal };

/// What was told to the target last: whole words, no padding, so that
/// utility.library's CompareMem tells two of them apart exactly.
const Told = extern struct {
    line: u32 = 0xFFFF_FFFF,
    column: u32 = 0,
    changed: u32 = 0,
    top: u32 = 0,
    total: u32 = 0,
    visible: u32 = 0,
    left: u32 = 0,
    widest: u32 = 0,
    width: u32 = 0,
};

/// textedit.gadget's part of an object.
pub const Data = struct {
    text: Text = undefined,
    history: undo.History = undefined,
    /// The text and the history are made.
    ready: bool = false,
    cursor: u32 = 0,
    anchor: u32 = 0,
    /// The column up and down keep to.
    goal_x: ?u32 = null,
    /// The first row shown, and how far the view is scrolled sideways.
    top: u32 = 0,
    left: u32 = 0,
    wrap: bool = false,
    read_only: bool = false,
    changed: bool = false,
    /// Scrollers of its own, rather than ones in the window's border.
    scrollers: bool = true,
    told: Told = .{},
    /// It has the keyboard.
    active: bool = false,
    /// A press in the text is held: the pointer selects.
    pressed: bool = false,
    scrolling: Scrolling = .none,
    vertical: ?*Object = null,
    horizontal: ?*Object = null,
    frame: ?*Object = null,
    /// The font the widths were measured in, and its line's height.
    font: ?*graphics.TextFont = null,
    line_height: i32 = 8,
    /// The last press, for a double one.
    last_secs: u32 = 0,
    last_micros: u32 = 0,
    last_press: u32 = 0xFFFF_FFFF,
};

// --- memory -----------------------------------------------------------------

fn allocFor(context: ?*anyopaque, size: u32) ?[*]u8 {
    const base: *gadgets.Base = @ptrCast(@alignCast(context.?));
    return @ptrCast(base.sys_base.AllocVec(size, exec.MEMF_ANY) orelse return null);
}

fn freeFor(context: ?*anyopaque, memory: [*]u8) void {
    const base: *gadgets.Base = @ptrCast(@alignCast(context.?));
    base.sys_base.FreeVec(memory);
}

fn memoryOf(base: *gadgets.Base) model.Memory {
    return .{ .context = base, .alloc = allocFor, .free = freeFor };
}

// --- where things are -------------------------------------------------------

/// The parts of the gadget, relative to its box: the field's frame, the
/// text inside it, the two scrollers, and how many rows the text shows.
const Parts = struct {
    frame: gc.Box,
    area: gc.Box,
    vertical: gc.Box,
    horizontal: gc.Box,
    visible: u32,
};

fn partsOf(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Parts {
    const g = gc.gadget(o);
    const b = gc.boxFor(g, gi);
    const across: i32 = if (own.scrollers) @min(scroll_size, b.width) else 0;
    const down: i32 = if (own.wrap or !own.scrollers) 0 else @min(scroll_size, b.height);
    const frame = gc.Box{ .width = @max(b.width - across, 0), .height = @max(b.height - down, 0) };
    const dri = if (gi) |info| info.draw_info else g.draw_info;
    const inset = support.frameInset(base.intuition_base, own.frame.?, dri);
    const area = gc.Box{
        .left = inset.left + text_margin,
        .top = inset.top + 1,
        .width = @max(frame.width - inset.width - 2 * text_margin, 0),
        .height = @max(frame.height - inset.height - 2, 0),
    };
    return .{
        .frame = frame,
        .area = area,
        .vertical = .{ .left = frame.width, .width = across, .height = frame.height },
        .horizontal = .{ .top = frame.height, .width = frame.width, .height = down },
        .visible = @intCast(@max(@divTrunc(area.height, @max(own.line_height, 1)), 1)),
    };
}

/// The widths of the font a byte at a time, the line's height, and the
/// rows laid out at the field's width: whenever the font or the width
/// they were made for is not the one there is.
fn syncLayout(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*const classusr.GadgetInfo) void {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, gc.gadget(o), gi);
    defer measure.done(ib);
    var again = false;
    if (measure.font) |font| {
        if (font != own.font) {
            own.font = font;
            var one: [2:0]u8 = .{ 0, 0 };
            for (&own.text.layout.widths, 0..) |*width, byte| {
                if (byte < 0x20 or (byte >= 0x7F and byte < 0xA0)) {
                    width.* = 0;
                    continue;
                }
                one[0] = @intCast(byte);
                const run = intuition.text.plainRun(&one, font);
                width.* = @intCast(@max(ib.IntuiTextLength(&run), 0));
            }
            own.text.layout.tab_stop = @max(8 * @as(u32, own.text.layout.widths[' ']), 1);
            own.line_height = @max(measure.lineHeight(base.graphics_base), 1);
            again = true;
        }
    }
    const wanted: u32 = if (own.wrap) @intCast(@max(partsOf(base, own, o, gi).area.width, 1)) else 0;
    if (wanted != own.text.layout.wrap_width) {
        own.text.layout.wrap_width = wanted;
        again = true;
    }
    if (again) _ = own.text.relayout();
}

/// The furthest the top goes: the last view that is full.
fn lastTop(own: *const Data, visible: u32) u32 {
    const rows = own.text.rowCount();
    return if (rows > visible) rows - visible else 0;
}

/// The view moved so that the cursor is in it.
fn showCursor(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*const classusr.GadgetInfo) void {
    const parts = partsOf(base, own, o, gi);
    const row = own.text.rowOf(own.cursor);
    if (row < own.top) own.top = row;
    if (row >= own.top + parts.visible) own.top = row + 1 - parts.visible;
    own.top = @min(own.top, lastTop(own, parts.visible));
    if (own.wrap) {
        own.left = 0;
        return;
    }
    const width: u32 = @intCast(@max(parts.area.width, 1));
    const x = own.text.xOf(own.cursor);
    // Past either edge, the view goes a quarter of its width further, so
    // that typing on does not move it at every character.
    if (x < own.left) own.left = x -| width / 4;
    if (x + cursor_width > own.left + width) own.left = x + cursor_width + width / 4 - width;
}

fn selection(own: *const Data) struct { from: u32, to: u32 } {
    return .{ .from = @min(own.cursor, own.anchor), .to = @max(own.cursor, own.anchor) };
}

// --- drawing ----------------------------------------------------------------

/// Bytes of a run gathered before they are drawn.
const run_room = 128;

const Pens = struct { text: u32, fill: u32, fill_text: u32 };

/// A run of a row's bytes drawn at `x` from the field's left.
fn drawRun(gb: *sdk.interface.graphics.GraphicsBase, rp: *graphics.RastPort, bytes: []const u8, left: i32, baseline: i32, pen: u32) void {
    if (bytes.len == 0) return;
    const tags = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = pen },
        .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 },
        .{},
    };
    gb.SetRPAttrs(rp, &tags);
    gb.Move(rp, left, baseline);
    gb.Text(rp, bytes.ptr, @intCast(bytes.len));
}

/// One row of the text, at `top` in the window, inside `area` (the
/// window's coordinates).
fn drawRow(base: *gadgets.Base, own: *const Data, rp: *graphics.RastPort, area: gc.Box, top: i32, baseline: i32, row: u32, pens: Pens) void {
    const gb = base.graphics_base;
    const text = &own.text;
    const start = text.rowStart(row);
    const end = text.rowEnd(row);
    const sel = selection(own);
    const view_left: i64 = own.left;
    const view_right: i64 = view_left + area.width;

    // The selection's ground: from where it starts in the row to where it
    // ends, or on to the field's edge when it goes on past the row.
    if (sel.from != sel.to and sel.from <= end and sel.to > start) {
        const from_x: i64 = if (sel.from <= start) 0 else text.xOf(sel.from);
        const goes_on = sel.to > end;
        const to_x: i64 = if (goes_on) view_right else text.xOf(sel.to);
        const left = @max(from_x, view_left);
        const right = @min(to_x, view_right);
        if (right > left) support.fill(gb, rp, .{
            .left = area.left + @as(i32, @intCast(left - view_left)),
            .top = top,
            .width = @intCast(right - left - 1),
            .height = own.line_height - 1,
        }, pens.fill);
    }

    var run: [run_room]u8 = undefined;
    var used: usize = 0;
    var run_left: i64 = 0;
    var run_selected = false;
    var x: u32 = 0;
    var at = start;
    while (at < end) : (at += 1) {
        const byte = text.byteAt(at);
        const width = text.widthAt(byte, x);
        const selected = at >= sel.from and at < sel.to;
        const shows = byte != '\t' and width != 0 and @as(i64, x) >= view_left and @as(i64, x) + width <= view_right;
        if (used != 0 and (!shows or selected != run_selected or used == run.len)) {
            drawRun(gb, rp, run[0..used], area.left + @as(i32, @intCast(run_left - view_left)), baseline, if (run_selected) pens.fill_text else pens.text);
            used = 0;
        }
        if (shows) {
            if (used == 0) {
                run_left = x;
                run_selected = selected;
            }
            run[used] = byte;
            used += 1;
        }
        x += width;
        if (@as(i64, x) > view_right and !own.wrap) break;
    }
    drawRun(gb, rp, run[0..used], area.left + @as(i32, @intCast(run_left - view_left)), baseline, if (run_selected) pens.fill_text else pens.text);

    // The cursor, while it has the keyboard.
    if (own.active and text.rowOf(own.cursor) == row) {
        const cursor_x: i64 = @as(i64, text.xOf(own.cursor)) - view_left;
        if (cursor_x >= 0 and cursor_x <= area.width) support.fill(gb, rp, .{
            .left = area.left + @as(i32, @intCast(cursor_x)) - 1,
            .top = top,
            .width = cursor_width - 1,
            .height = own.line_height - 1,
        }, pens.text);
    }
}

fn render(base: *gadgets.Base, cl: *Class, o: *Object, r: *gc.GpRender) void {
    const info = r.gadget_info orelse return;
    const ib = base.intuition_base;
    const gb = base.graphics_base;
    const own = classes.instData(Data, cl, o);
    if (!own.ready) return;
    const rp = r.rast_port;
    const saved = support.Saved.of(gb, rp);
    defer saved.restore(gb, rp);
    syncLayout(base, own, o, info);
    const g = gc.gadget(o);
    const b = gc.boxFor(g, info);
    const parts = partsOf(base, own, o, info);
    own.top = @min(own.top, lastTop(own, parts.visible));

    support.drawFrame(ib, own.frame.?, rp, .{ .left = b.left, .top = b.top, .width = parts.frame.width, .height = parts.frame.height }, ic.IDS_NORMAL, info.draw_info, g.style);
    const ground = support.background(ib, info.draw_info, g.style, ic.PART_FIELD);
    const area = gc.Box{ .left = b.left + parts.area.left, .top = b.top + parts.area.top, .width = parts.area.width, .height = parts.area.height };
    support.fill(gb, rp, .{ .left = area.left - text_margin, .top = area.top, .width = area.width + 2 * text_margin - 1, .height = area.height - 1 }, ground);

    const styled = support.pensFor(ib, info.draw_info, g.style, ic.PART_FIELD, sdk.intuition.style.PART_SELECTION);
    const pens = Pens{ .text = styled[sc.TEXTPEN], .fill = styled[sc.FILLPEN], .fill_text = styled[sc.FILLTEXTPEN] };
    if (own.font) |font| {
        const set = [_]TagItem{ .{ .tag = graphics.RPTAG_Font, .data = @intFromPtr(font) }, .{} };
        gb.SetRPAttrs(rp, &set);
    }
    var baseline: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) }, .{} };
    gb.GetRPAttrs(rp, &ask);

    var shown: u32 = 0;
    while (shown < parts.visible) : (shown += 1) {
        const row = own.top + shown;
        if (row >= own.text.rowCount()) break;
        const top = area.top + @as(i32, @intCast(shown)) * own.line_height;
        drawRow(base, own, rp, area, top, top + @as(i32, @intCast(baseline)), row, pens);
    }

    putScrollers(base, own, o, null);
    if (own.vertical) |scroller| {
        place(base, scroller, b, parts.vertical);
        _ = ib.SendMessage(scroller, @ptrCast(r));
    }
    if (!own.wrap) if (own.horizontal) |scroller| {
        place(base, scroller, b, parts.horizontal);
        _ = ib.SendMessage(scroller, @ptrCast(r));
        // The corner the two leave between them.
        support.fill(gb, rp, .{ .left = b.left + parts.frame.width, .top = b.top + parts.frame.height, .width = parts.vertical.width - 1, .height = parts.horizontal.height - 1 }, info.draw_info.pens[sc.BACKGROUNDPEN]);
    };
    if (g.flags & gc.GFLG_DISABLED != 0) support.ghost(gb, rp, b, info.block_pen);
}

/// An inner gadget put at its part of the box, in the window's coordinates.
fn place(base: *gadgets.Base, inner: *Object, b: gc.Box, at: gc.Box) void {
    support.place(base.intuition_base, inner, .{ .left = b.left + at.left, .top = b.top + at.top, .width = at.width, .height = at.height });
}

/// The scrollers told how much there is, how much shows, and where the view
/// is.
fn putScrollers(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const ib = base.intuition_base;
    const parts = partsOf(base, own, o, gi);
    if (own.vertical) |scroller| {
        const tags = [_]TagItem{
            .{ .tag = sr.SCROLLER_Total, .data = own.text.rowCount() },
            .{ .tag = sr.SCROLLER_Visible, .data = parts.visible },
            .{ .tag = sr.SCROLLER_Top, .data = own.top },
            .{},
        };
        var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
        _ = ib.SendMessage(scroller, @ptrCast(&set));
    }
    if (own.horizontal) |scroller| {
        const width: u32 = @intCast(@max(parts.area.width, 1));
        const total = @max(own.text.widest + cursor_width, own.left + width);
        const tags = [_]TagItem{
            .{ .tag = sr.SCROLLER_Total, .data = total },
            .{ .tag = sr.SCROLLER_Visible, .data = width },
            .{ .tag = sr.SCROLLER_Top, .data = own.left },
            .{},
        };
        var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags, .gadget_info = gi };
        _ = ib.SendMessage(scroller, @ptrCast(&set));
    }
}

/// Drawn again, and the target told where the cursor is now.
fn refresh(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    support.redraw(base.intuition_base, o, gi);
    tell(base, own, o, gi);
}

/// What there is to tell now.
fn nowTold(base: *gadgets.Base, own: *const Data, o: *Object, gi: ?*const classusr.GadgetInfo) Told {
    const parts = partsOf(base, own, o, gi);
    const line = own.text.lineOf(own.cursor);
    const width: u32 = @intCast(@max(parts.area.width, 1));
    return .{
        .line = line,
        .column = own.cursor - own.text.lineStart(line),
        .changed = @intFromBool(own.changed),
        .top = @min(own.top, lastTop(own, parts.visible)),
        .total = own.text.rowCount(),
        .visible = parts.visible,
        .left = own.left,
        .widest = if (own.wrap) width else @max(own.text.widest + cursor_width, own.left + width),
        .width = width,
    };
}

/// The target told the cursor, the change and the view - when any of them
/// is not what it was told last.
fn tell(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const now = nowTold(base, own, o, gi);
    if (base.utility_base.CompareMem(&now, &own.told, @sizeOf(Told)) == 0) return;
    own.told = now;
    const tags = [_]TagItem{
        .{ .tag = te.TEXTEDIT_CursorLine, .data = now.line },
        .{ .tag = te.TEXTEDIT_CursorColumn, .data = now.column },
        .{ .tag = te.TEXTEDIT_Changed, .data = now.changed },
        .{ .tag = te.TEXTEDIT_TopVert, .data = now.top },
        .{ .tag = te.TEXTEDIT_TotalVert, .data = now.total },
        .{ .tag = te.TEXTEDIT_VisibleVert, .data = now.visible },
        .{ .tag = te.TEXTEDIT_TopHoriz, .data = now.left },
        .{ .tag = te.TEXTEDIT_TotalHoriz, .data = now.widest },
        .{ .tag = te.TEXTEDIT_VisibleHoriz, .data = now.width },
        .{ .tag = gc.GA_ID, .data = gc.gadget(o).id },
        .{},
    };
    support.notify(base.intuition_base, o, gi, &tags, 0);
}

// --- editing ----------------------------------------------------------------

/// The text from `from` up to `to` replaced with `bytes`, kept for undo,
/// the cursor after it. False when it could not be: read-only, or no
/// memory.
fn replace(base: *gadgets.Base, own: *Data, from: u32, to: u32, bytes: []const u8, typing: bool) bool {
    if (own.read_only) return false;
    const sys = base.sys_base;
    const count = to - from;
    var held: [256]u8 = undefined;
    var taken: ?[*]u8 = null;
    defer if (taken) |memory| sys.FreeVec(memory);
    const removed: []u8 = if (count <= held.len) held[0..count] else blk: {
        const memory: [*]u8 = @ptrCast(sys.AllocVec(count, exec.MEMF_ANY) orelse return false);
        taken = memory;
        break :blk memory[0..count];
    };
    own.text.copyOut(from, to, removed.ptr);
    own.text.remove(from, to);
    if (!own.text.insert(from, bytes)) {
        // No room for what goes in: what came out goes back.
        _ = own.text.insert(from, removed);
        return false;
    }
    own.history.record(from, removed, bytes, own.cursor, own.anchor, typing);
    own.cursor = from + @as(u32, @intCast(bytes.len));
    own.anchor = own.cursor;
    own.goal_x = null;
    own.changed = true;
    return true;
}

/// What is selected replaced with `bytes`, or `bytes` put in at the
/// cursor.
fn typeIn(base: *gadgets.Base, own: *Data, bytes: []const u8, typing: bool) bool {
    const sel = selection(own);
    if (sel.from != sel.to and typing) own.history.seal();
    return replace(base, own, sel.from, sel.to, bytes, typing and sel.from == sel.to);
}

fn undoLast(own: *Data) bool {
    const step = own.history.toUndo() orelse return false;
    own.text.remove(step.at, step.at + step.inserted_len);
    if (!own.text.insert(step.at, step.removed())) return false;
    own.cursor = step.cursor;
    own.anchor = step.anchor;
    own.history.undone();
    own.history.seal();
    own.goal_x = null;
    own.changed = true;
    return true;
}

fn redoNext(own: *Data) bool {
    const step = own.history.toRedo() orelse return false;
    own.text.remove(step.at, step.at + step.removed_len);
    if (!own.text.insert(step.at, step.inserted())) return false;
    own.cursor = step.at + step.inserted_len;
    own.anchor = own.cursor;
    own.history.redone();
    own.goal_x = null;
    own.changed = true;
    return true;
}

/// Every match of `needle` replaced with `with`, as one step of undo: the
/// whole text taken as the step's before and after. How many.
fn replaceAll(base: *gadgets.Base, own: *Data, needle: []const u8, with: []const u8, any_case: bool) u32 {
    if (own.read_only or needle.len == 0) return 0;
    const sys = base.sys_base;
    const length = own.text.length();
    const before: [*]u8 = @ptrCast(sys.AllocVec(@max(length, 1), exec.MEMF_ANY) orelse return 0);
    defer sys.FreeVec(before);
    own.text.copyOut(0, length, before);
    var count: u32 = 0;
    var at: u32 = 0;
    while (at + needle.len <= own.text.length()) {
        if (!own.text.matchAt(at, needle, any_case)) {
            at += 1;
            continue;
        }
        own.text.remove(at, at + @as(u32, @intCast(needle.len)));
        if (!own.text.insert(at, with)) break;
        at += @intCast(with.len);
        count += 1;
    }
    if (count == 0) return 0;
    const after_length = own.text.length();
    const after: [*]u8 = @ptrCast(sys.AllocVec(@max(after_length, 1), exec.MEMF_ANY) orelse {
        own.history.deinit();
        own.history = undo.History.init(memoryOf(base));
        return count;
    });
    defer sys.FreeVec(after);
    own.text.copyOut(0, after_length, after);
    own.history.record(0, before[0..length], after[0..after_length], own.cursor, own.anchor, false);
    own.cursor = @min(own.cursor, after_length);
    own.anchor = own.cursor;
    own.changed = true;
    return count;
}

/// The next match selected, from the cursor on; whether there was one.
fn findNext(own: *Data, needle: []const u8, flags: u32) bool {
    const backwards = flags & te.TEFF_BACKWARDS != 0;
    const sel = selection(own);
    const from = if (backwards) sel.from else sel.to;
    const at = own.text.find(from, needle, backwards, flags & te.TEFF_ANYCASE != 0) orelse return false;
    own.anchor = at;
    own.cursor = at + @as(u32, @intCast(needle.len));
    own.goal_x = null;
    own.history.seal();
    return true;
}

// --- moving -----------------------------------------------------------------

/// The cursor moved to `pos`; the anchor too unless `extend`.
fn moveTo(own: *Data, pos: u32, extend: bool, keep_goal: bool) void {
    own.cursor = @min(pos, own.text.length());
    if (!extend) own.anchor = own.cursor;
    if (!keep_goal) own.goal_x = null;
    own.history.seal();
}

/// The cursor a row up or down, `count` of them, kept to its column.
fn moveRows(own: *Data, down: bool, count: u32, extend: bool) void {
    const text = &own.text;
    const goal = own.goal_x orelse text.xOf(own.cursor);
    const row = text.rowOf(own.cursor);
    const wanted: u32 = if (down) @min(row + count, text.rowCount() - 1) else row -| count;
    const pos = if (down and row == text.rowCount() - 1) text.length() else if (!down and row == 0) 0 else text.posAt(wanted, goal);
    moveTo(own, pos, extend, true);
    own.goal_x = goal;
}

/// What a key that moves the cursor does. True when it was one.
fn moveKey(own: *Data, code: u32, qualifier: u32, page: u32) bool {
    const text = &own.text;
    const extend = qualifier & SHIFT != 0;
    const control = qualifier & ie.IEQUALIFIER_CONTROL != 0;
    const sel = selection(own);
    switch (code) {
        RAW_LEFT => {
            if (sel.from != sel.to and !extend) moveTo(own, sel.from, false, false) else if (control) moveTo(own, text.wordBefore(own.cursor), extend, false) else moveTo(own, own.cursor -| 1, extend, false);
        },
        RAW_RIGHT => {
            if (sel.from != sel.to and !extend) moveTo(own, sel.to, false, false) else if (control) moveTo(own, text.wordAfter(own.cursor), extend, false) else moveTo(own, own.cursor + 1, extend, false);
        },
        RAW_UP => if (control) moveTo(own, 0, extend, false) else moveRows(own, false, 1, extend),
        RAW_DOWN => if (control) moveTo(own, text.length(), extend, false) else moveRows(own, true, 1, extend),
        RAW_HOME => moveTo(own, if (control) 0 else text.rowStart(text.rowOf(own.cursor)), extend, false),
        RAW_END => moveTo(own, if (control) text.length() else text.rowEnd(text.rowOf(own.cursor)), extend, false),
        RAW_PAGEUP => {
            own.top -|= page;
            moveRows(own, false, page, extend);
        },
        RAW_PAGEDOWN => {
            own.top += page;
            moveRows(own, true, page, extend);
        },
        else => return false,
    }
    return true;
}

/// A key while the gadget has the keyboard: what it answers.
fn key(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput, e: *const ie.InputEvent) usize {
    if (e.code & ie.IECODE_UP_PREFIX != 0) return gc.GMR_MEACTIVE;
    // A menu's shortcut is the window's.
    if (e.qualifier & COMMAND != 0) return giveBack(base, own, o, in.gadget_info);
    const parts = partsOf(base, own, o, in.gadget_info);
    const page = @max(parts.visible, 2) - 1;
    if (moveKey(own, e.code, e.qualifier, page)) {
        showCursor(base, own, o, in.gadget_info);
        refresh(base, own, o, in.gadget_info);
        return gc.GMR_MEACTIVE;
    }
    const sel = selection(own);
    var did = false;
    switch (e.code) {
        RAW_BACKSPACE => {
            if (sel.from != sel.to) {
                did = replace(base, own, sel.from, sel.to, "", false);
            } else if (own.cursor > 0) {
                const from = if (e.qualifier & ie.IEQUALIFIER_CONTROL != 0) own.text.wordBefore(own.cursor) else own.cursor - 1;
                did = replace(base, own, from, own.cursor, "", true);
            }
        },
        RAW_DELETE => {
            if (sel.from != sel.to) {
                did = replace(base, own, sel.from, sel.to, "", false);
            } else if (own.cursor < own.text.length()) {
                const to = if (e.qualifier & ie.IEQUALIFIER_CONTROL != 0) own.text.wordAfter(own.cursor) else own.cursor + 1;
                did = replace(base, own, own.cursor, to, "", true);
            }
        },
        RAW_RETURN, RAW_ENTER => did = typeIn(base, own, "\n", true),
        RAW_TAB => did = typeIn(base, own, "\t", true),
        RAW_ESCAPE => {
            moveTo(own, own.cursor, false, false);
            did = sel.from != sel.to;
        },
        else => {
            const kb: *KeymapBase = @ptrCast(base.opened[1] orelse return gc.GMR_MEACTIVE);
            var mapped: [8]u8 = undefined;
            if (kb.MapRawKey(e, &mapped, mapped.len, null) != 1) return gc.GMR_MEACTIVE;
            var char = mapped[0];
            if (e.qualifier & ie.IEQUALIFIER_CONTROL != 0) {
                // Control with a letter, whatever the keymap made of it.
                if ((char | 0x20) >= 'a' and (char | 0x20) <= 'z') char = (char | 0x20) - 'a' + 1;
                switch (char) {
                    0x01 => {
                        own.anchor = 0;
                        own.cursor = own.text.length();
                        own.history.seal();
                        did = true;
                    },
                    0x1A => did = undoLast(own),
                    0x19 => did = redoNext(own),
                    // Copy, cut and paste: the program's.
                    0x03, 0x18, 0x16 => return giveBack(base, own, o, in.gadget_info),
                    else => return gc.GMR_MEACTIVE,
                }
            } else if (char >= 0x20 and char != 0x7F and !(char >= 0x80 and char < 0xA0)) {
                did = typeIn(base, own, mapped[0..1], true);
            } else return gc.GMR_MEACTIVE;
        },
    }
    if (!did) {
        if (own.read_only) {
            if (in.gadget_info) |gi| base.intuition_base.DisplayBeep(gi.screen);
        }
        return gc.GMR_MEACTIVE;
    }
    showCursor(base, own, o, in.gadget_info);
    refresh(base, own, o, in.gadget_info);
    return gc.GMR_MEACTIVE;
}

/// The keyboard handed back with the event, which goes on to the window.
fn giveBack(base: *gadgets.Base, own: *Data, o: *Object, gi: ?*classusr.GadgetInfo) usize {
    own.active = false;
    own.pressed = false;
    support.redraw(base.intuition_base, o, gi);
    return gc.GMR_REUSE;
}

/// The position under the pointer, `x` and `y` from the gadget's corner;
/// rows above and below the field are the first and last shown.
fn posUnder(own: *const Data, parts: Parts, x: i32, y: i32) u32 {
    const text = &own.text;
    const row_in = @divFloor(y - parts.area.top, @max(own.line_height, 1));
    const row_i64 = @as(i64, own.top) + row_in;
    const row: u32 = @intCast(@max(@min(row_i64, @as(i64, text.rowCount()) - 1), 0));
    return text.posAt(row, @as(i64, x - parts.area.left) + own.left);
}

/// A press in the text: the cursor there, the selection made to it with
/// Shift, a word with a second press.
fn pressAt(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput, e: *const ie.InputEvent) void {
    const parts = partsOf(base, own, o, in.gadget_info);
    const pos = posUnder(own, parts, in.mouse.x, in.mouse.y);
    const double = pos == own.last_press and base.intuition_base.DoubleClick(own.last_secs, own.last_micros, e.time.secs, e.time.micro);
    own.last_press = if (double) 0xFFFF_FFFF else pos;
    own.last_secs = e.time.secs;
    own.last_micros = e.time.micro;
    if (double) {
        const word = own.text.wordAround(pos);
        own.anchor = word.from;
        moveTo(own, word.to, true, false);
        own.pressed = false;
    } else {
        moveTo(own, pos, e.qualifier & SHIFT != 0, false);
        own.pressed = true;
    }
    refresh(base, own, o, in.gadget_info);
}

/// Which scroller a point in the gadget is on.
fn scrollerAt(own: *const Data, parts: Parts, x: i32, y: i32) Scrolling {
    if (x >= parts.vertical.left and y < parts.vertical.height) return .vertical;
    if (!own.wrap and y >= parts.horizontal.top and x < parts.horizontal.width) return .horizontal;
    return .none;
}

fn scrollerOf(own: *const Data, which: Scrolling) ?*Object {
    return switch (which) {
        .vertical => own.vertical,
        .horizontal => own.horizontal,
        .none => null,
    };
}

/// The input handed to a scroller, placed first.
fn toScroller(base: *gadgets.Base, own: *Data, o: *Object, in: *gc.GpInput, which: Scrolling) usize {
    const scroller = scrollerOf(own, which) orelse return gc.GMR_MEACTIVE;
    const b = gc.boxFor(gc.gadget(o), in.gadget_info);
    const parts = partsOf(base, own, o, in.gadget_info);
    const at = if (which == .vertical) parts.vertical else parts.horizontal;
    place(base, scroller, b, at);
    return support.handOnInput(base.intuition_base, scroller, in, at);
}

// --- attributes -------------------------------------------------------------

/// What a tag list asks of the text: a new text, wrap, read-only, changed.
/// Whether it changes what is shown.
fn setAttrs(base: *gadgets.Base, own: *Data, tags: ?[*]const TagItem) bool {
    const ub = base.utility_base;
    var shows = false;
    if (ub.FindTagItem(te.TEXTEDIT_Text, tags)) |item| {
        const length: u32 = @truncate(ub.GetTagData(te.TEXTEDIT_TextLength, 0, tags));
        const bytes: [*]const u8 = if (item.data == 0) "" else @ptrFromInt(item.data);
        if (own.text.setAll(bytes[0..if (item.data == 0) 0 else length])) {
            own.history.deinit();
            own.history = undo.History.init(memoryOf(base));
            own.cursor = 0;
            own.anchor = 0;
            own.top = 0;
            own.left = 0;
            own.goal_x = null;
            own.changed = false;
            shows = true;
        }
    }
    if (ub.FindTagItem(te.TEXTEDIT_WordWrap, tags)) |item| {
        const wrap = item.data != 0;
        if (wrap != own.wrap) {
            own.wrap = wrap;
            own.left = 0;
            shows = true;
        }
    }
    if (ub.FindTagItem(te.TEXTEDIT_ReadOnly, tags)) |item| own.read_only = item.data != 0;
    if (ub.FindTagItem(te.TEXTEDIT_Changed, tags)) |item| own.changed = item.data != 0;
    return shows;
}

fn domain(base: *gadgets.Base, own: *const Data, g: *const gc.Gadget, gi: ?*const classusr.GadgetInfo, which: u32) gc.Box {
    const ib = base.intuition_base;
    const measure = support.Measure.of(ib, g, gi);
    defer measure.done(ib);
    const line: i32 = @max(measure.lineHeight(base.graphics_base), 1);
    const em: i32 = @max(measure.width(ib, "M"), 1);
    const bar: i32 = if (own.scrollers) scroll_size else 0;
    const extra: i32 = bar + 2 * text_margin + 8;
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = 8 * em + extra, .height = 3 * line + bar + 8 },
        gc.GDOMAIN_MAXIMUM => .{ .width = gc.GDOMAIN_UNLIMITED, .height = gc.GDOMAIN_UNLIMITED },
        else => .{ .width = 60 * em + extra, .height = 20 * line + bar + 8 },
    };
}

// --- the dispatcher ---------------------------------------------------------

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
            const memory = memoryOf(base);
            own.history = undo.History.init(memory);
            if (Text.init(memory)) |text| {
                own.text = text;
                own.ready = true;
            }
            own.scrollers = base.utility_base.GetTagData(te.TEXTEDIT_Scrollers, 1, new.attr_list) != 0;
            const frame_tags = [_]TagItem{ .{ .tag = ic.IA_StylePart, .data = ic.PART_FIELD }, .{} };
            if (own.ready) own.frame = ib.NewObjectTagList(null, classusr.FRAMEICLASS, &frame_tags);
            const vertical_tags = [_]TagItem{
                .{ .tag = pg.PGA_Freedom, .data = pg.FREEVERT },
                .{ .tag = sr.SCROLLER_Arrows, .data = scroll_size },
                .{ .tag = icc.ICA_TARGET, .data = made },
                .{},
            };
            const horizontal_tags = [_]TagItem{
                .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
                .{ .tag = sr.SCROLLER_Arrows, .data = scroll_size },
                .{ .tag = icc.ICA_TARGET, .data = made },
                .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&left_map) },
                .{},
            };
            if (own.frame != null and own.scrollers) {
                own.vertical = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &vertical_tags);
                own.horizontal = ib.NewObjectTagList(null, sr.SCROLLER_CLASS, &horizontal_tags);
            }
            if (own.frame == null or (own.scrollers and (own.vertical == null or own.horizontal == null))) {
                ib.DisposeObject(own.vertical);
                ib.DisposeObject(own.horizontal);
                ib.DisposeObject(own.frame);
                if (own.ready) {
                    own.text.deinit();
                    own.history.deinit();
                }
                var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };
                _ = ib.SendSuperMessage(cl, obj, &gone);
                return 0;
            }
            _ = setAttrs(base, own, new.attr_list);
            const g = gc.gadget(obj);
            g.flags |= gc.GFLG_TYPING | gc.GFLG_TABCYCLE;
            // As big as it looks right, unless given a size.
            const ub = base.utility_base;
            const sized = ub.FindTagItem(gc.GA_Width, new.attr_list) != null or ub.FindTagItem(gc.GA_Height, new.attr_list) != null;
            if (!sized) {
                const size = domain(base, own, g, null, gc.GDOMAIN_NOMINAL);
                const tags = [_]TagItem{
                    .{ .tag = gc.GA_Width, .data = @intCast(size.width) },
                    .{ .tag = gc.GA_Height, .data = @intCast(size.height) },
                    .{},
                };
                var set = classusr.OpSet{ .method_id = classusr.OM_SET, .attr_list = &tags };
                _ = ib.SendSuperMessage(cl, obj, @ptrCast(&set));
            }
            syncLayout(base, own, obj, null);
            return made;
        },
        classusr.OM_DISPOSE => {
            const own = classes.instData(Data, cl, o orelse return 0);
            ib.DisposeObject(own.vertical);
            ib.DisposeObject(own.horizontal);
            ib.DisposeObject(own.frame);
            if (own.ready) {
                own.text.deinit();
                own.history.deinit();
                own.ready = false;
            }
            return ib.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const ub = base.utility_base;
            // A scroller moving - its own, or one in the window's border -
            // or a program setting the view: the view follows, and the
            // cursor stays where it is.
            var moved = false;
            if (msg.method_id == classusr.OM_UPDATE) if (ub.FindTagItem(sr.SCROLLER_Top, set.attr_list)) |item| {
                own.top = @truncate(item.data);
                moved = true;
            };
            if (ub.FindTagItem(te.TEXTEDIT_TopVert, set.attr_list)) |item| {
                own.top = @truncate(item.data);
                moved = true;
            }
            if (ub.FindTagItem(te.TEXTEDIT_TopHoriz, set.attr_list)) |item| {
                own.left = if (own.wrap) 0 else @truncate(item.data);
                moved = true;
            }
            if (moved) {
                own.top = @min(own.top, lastTop(own, partsOf(base, own, o.?, set.gadget_info).visible));
                support.redraw(ib, o.?, set.gadget_info);
                tell(base, own, o.?, set.gadget_info);
                if (msg.method_id == classusr.OM_UPDATE) return 0;
            }
            var shows = ib.SendSuperMessage(cl, o, msg) != 0;
            if (setAttrs(base, own, set.attr_list)) shows = true;
            if (shows and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                syncLayout(base, own, o.?, set.gadget_info);
                showCursor(base, own, o.?, set.gadget_info);
                support.redraw(ib, o.?, set.gadget_info);
                tell(base, own, o.?, set.gadget_info);
                return 0;
            }
            return @intFromBool(shows or moved);
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const line = own.text.lineOf(own.cursor);
            get.storage.* = switch (get.attr_id) {
                te.TEXTEDIT_Length => own.text.length(),
                te.TEXTEDIT_WordWrap => @intFromBool(own.wrap),
                te.TEXTEDIT_ReadOnly => @intFromBool(own.read_only),
                te.TEXTEDIT_Changed => @intFromBool(own.changed),
                te.TEXTEDIT_CursorLine => line,
                te.TEXTEDIT_CursorColumn => own.cursor - own.text.lineStart(line),
                te.TEXTEDIT_Lines => own.text.lineCount(),
                te.TEXTEDIT_TopVert => nowTold(base, own, o.?, null).top,
                te.TEXTEDIT_TotalVert => own.text.rowCount(),
                te.TEXTEDIT_VisibleVert => nowTold(base, own, o.?, null).visible,
                te.TEXTEDIT_TopHoriz => own.left,
                te.TEXTEDIT_TotalHoriz => nowTold(base, own, o.?, null).widest,
                te.TEXTEDIT_VisibleHoriz => nowTold(base, own, o.?, null).width,
                te.TEXTEDIT_Scrollers => @intFromBool(own.scrollers),
                else => return ib.SendSuperMessage(cl, o, msg),
            };
            return 1;
        },
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(base, classes.instData(Data, cl, o.?), gc.gadget(o.?), ask.gadget_info, ask.which);
            return 1;
        },
        gc.GM_LAYOUT => {
            const layout: *gc.GpLayout = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            syncLayout(base, own, o.?, layout.gadget_info);
            showCursor(base, own, o.?, layout.gadget_info);
            tell(base, own, o.?, layout.gadget_info);
            return ib.SendSuperMessage(cl, o, msg);
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
        // The key that works it gives it the keyboard.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            return if (gc.keyIsFor(o.?, k)) gc.GMKR_ACTIVATE else gc.GMKR_NOTHING;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (!own.ready) return gc.GMR_NOREUSE;
            const e = in.event orelse {
                // Given the keyboard by the program or by Tab.
                own.active = true;
                refresh(base, own, o.?, in.gadget_info);
                return gc.GMR_MEACTIVE;
            };
            const parts = partsOf(base, own, o.?, in.gadget_info);
            const which = scrollerAt(own, parts, in.mouse.x, in.mouse.y);
            if (which != .none) {
                const result = toScroller(base, own, o.?, in, which);
                if (result == gc.GMR_MEACTIVE) own.scrolling = which;
                return result & ~gc.GMR_VERIFY;
            }
            own.active = true;
            pressAt(base, own, o.?, in, e);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            if (own.scrolling != .none) {
                const result = toScroller(base, own, o.?, in, own.scrolling);
                if (result == gc.GMR_MEACTIVE) return gc.GMR_MEACTIVE;
                own.scrolling = .none;
                // A scroller let go: the keyboard stays where it was.
                return if (own.active) gc.GMR_MEACTIVE else result & ~gc.GMR_VERIFY;
            }
            const e = in.event orelse return gc.GMR_MEACTIVE;
            switch (e.class) {
                ie.IECLASS_RAWKEY => return key(base, own, o.?, in, e),
                ie.IECLASS_NEWPOINTERPOS => {
                    const b = gc.boxFor(gc.gadget(o.?), in.gadget_info);
                    const parts = partsOf(base, own, o.?, in.gadget_info);
                    switch (e.code) {
                        ie.IECODE_LBUTTON => {
                            if (!support.inside(in.mouse.x, in.mouse.y, b.width, b.height)) {
                                own.active = false;
                                own.pressed = false;
                                refresh(base, own, o.?, in.gadget_info);
                                return gc.GMR_REUSE;
                            }
                            const which = scrollerAt(own, parts, in.mouse.x, in.mouse.y);
                            if (which != .none) {
                                if (toScroller(base, own, o.?, in, which) == gc.GMR_MEACTIVE) own.scrolling = which;
                                return gc.GMR_MEACTIVE;
                            }
                            pressAt(base, own, o.?, in, e);
                        },
                        ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX => own.pressed = false,
                        // The menu button: the window's menus.
                        ie.IECODE_RBUTTON => return giveBack(base, own, o.?, in.gadget_info),
                        else => if (own.pressed) {
                            const pos = posUnder(own, parts, in.mouse.x, in.mouse.y);
                            if (pos != own.cursor) {
                                moveTo(own, pos, true, false);
                                showCursor(base, own, o.?, in.gadget_info);
                                refresh(base, own, o.?, in.gadget_info);
                            }
                        },
                    }
                },
                // Held past the top or the bottom: a row each tick.
                ie.IECLASS_TIMER => if (own.pressed) {
                    const parts = partsOf(base, own, o.?, in.gadget_info);
                    const above = in.mouse.y < parts.area.top;
                    const below = in.mouse.y >= parts.area.top + parts.area.height;
                    if (above or below) {
                        moveRows(own, below, 1, true);
                        showCursor(base, own, o.?, in.gadget_info);
                        refresh(base, own, o.?, in.gadget_info);
                    }
                },
                else => {},
            }
            return gc.GMR_MEACTIVE;
        },
        gc.GM_GOINACTIVE => {
            const gone: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            own.pressed = false;
            if (own.scrolling != .none) {
                const scroller = scrollerOf(own, own.scrolling).?;
                own.scrolling = .none;
                _ = ib.SendMessage(scroller, msg);
            }
            if (own.active) {
                own.active = false;
                support.redraw(ib, o.?, gone.gadget_info);
            }
            return 0;
        },
        te.TEM_GETTEXT, te.TEM_SELECTION => {
            const ask: *te.TepText = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const sel = selection(own);
            const from = if (msg.method_id == te.TEM_GETTEXT) 0 else sel.from;
            const to = if (msg.method_id == te.TEM_GETTEXT) own.text.length() else sel.to;
            if (ask.buffer) |buffer| own.text.copyOut(from, @min(to, from + ask.size), buffer);
            return to - from;
        },
        te.TEM_INSERT => {
            const in: *te.TepInsert = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const bytes: []const u8 = if (in.text) |text| text[0..in.length] else &.{};
            own.history.seal();
            const sel = selection(own);
            if (sel.from == sel.to and bytes.len == 0) return 0;
            if (!replace(base, own, sel.from, sel.to, bytes, false)) return 0;
            showCursor(base, own, o.?, in.gadget_info);
            refresh(base, own, o.?, in.gadget_info);
            return 1;
        },
        te.TEM_UNDO, te.TEM_REDO, te.TEM_SELECTALL => {
            const command: *te.TepCommand = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const did = switch (msg.method_id) {
                te.TEM_UNDO => !own.read_only and undoLast(own),
                te.TEM_REDO => !own.read_only and redoNext(own),
                else => blk: {
                    own.anchor = 0;
                    own.cursor = own.text.length();
                    own.history.seal();
                    break :blk true;
                },
            };
            if (!did) return 0;
            showCursor(base, own, o.?, command.gadget_info);
            refresh(base, own, o.?, command.gadget_info);
            return 1;
        },
        te.TEM_FIND, te.TEM_REPLACE, te.TEM_REPLACEALL => {
            const find: *te.TepFind = @ptrCast(@alignCast(msg));
            const own = classes.instData(Data, cl, o.?);
            const needle = find.text[0..find.length];
            const with: []const u8 = if (find.with) |text| text[0..find.with_length] else &.{};
            const any_case = find.flags & te.TEFF_ANYCASE != 0;
            var answer: usize = 0;
            switch (msg.method_id) {
                te.TEM_FIND => answer = @intFromBool(findNext(own, needle, find.flags)),
                te.TEM_REPLACE => {
                    const sel = selection(own);
                    if (sel.to - sel.from == needle.len and own.text.matchAt(sel.from, needle, any_case)) {
                        own.history.seal();
                        if (replace(base, own, sel.from, sel.to, with, false)) answer = 1;
                    }
                    _ = findNext(own, needle, find.flags);
                },
                else => {
                    own.history.seal();
                    answer = replaceAll(base, own, needle, with, any_case);
                },
            }
            showCursor(base, own, o.?, find.gadget_info);
            refresh(base, own, o.?, find.gadget_info);
            return answer;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
