// SPDX-License-Identifier: MPL-2.0
//! strgclass: a line of text a person types.
//!
//! The gadget holds a buffer and a cursor in it. While it is active the
//! keys edit that buffer - characters go in at the cursor, the cursor
//! keys and Home and End move it, Backspace and Delete take a character
//! out - and the box shows as much of the line as fits, scrolled to keep
//! the cursor in view. Return finishes it, and Escape puts back what the
//! text was when it was activated.
//!
//! The buffer is the caller's (`STRINGA_Buffer`), so a program reads what
//! was typed where it put what it started with. A gadget told only how
//! much room to have takes a buffer of its own and gives it back when it
//! is disposed of.
//!
//! Keys arrive as raw key events and are read through keymap.library, so
//! the keymap in force is the one the rest of the machine uses, and a
//! gadget may name another with `STRINGA_AltKeyMap`.
//!
//! A key is edited in two steps (`sghooks.zig`): the text is copied into
//! the work buffer, the global edit hook - `defaultEdit` here, until
//! `SetEditHook` puts another - makes of the key what it will there, and
//! the gadget's own hook (`STRINGA_EditHook`) may change that. Then what
//! the `SGWork`'s actions say is done: the work taken as the text, the
//! gadget ended, the screen flashed.

const sdk = @import("sdk");
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sg = intuition.sghooks;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const km = sdk.keymap;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const gadgetclass = @import("gadgetclass.zig");
const _gadget = @import("../gadget/_gadget.zig");
const d = @import("draw.zig");

/// strgclass's part of an object.
pub const Data = extern struct {
    /// What is being typed into, and how much room it has.
    buffer: ?[*]u8 = null,
    undo: ?[*]u8 = null,
    max_chars: u32 = gc.SG_DEFAULTMAXCHARS,
    /// Where the cursor is and which character is shown first.
    buffer_pos: u32 = 0,
    disp_pos: u32 = 0,
    num_chars: u32 = 0,
    /// The text as a number, kept up to date with it.
    long_val: i32 = 0,
    /// GACT_STRING: which edge the text sits against.
    justification: u32 = gc.GACT_STRINGLEFT,
    /// `SGM_` modes: replace, fixed field, no filter, exit on Help.
    modes: u32 = 0,
    /// The work buffer an edit is made in, as long as the buffer.
    work: ?[*]u8 = null,
    owns_work: u8 = 0,
    /// `STRINGA_EditHook`: called for each key after the global hook.
    edit_hook: ?*utility.Hook = null,
    /// The gadget took its own buffer and gives it back.
    owns_buffer: u8 = 0,
    /// The same for the undo room, which it may own without owning the
    /// buffer: a caller that supplies text to edit rarely supplies
    /// somewhere to keep the old copy.
    owns_undo: u8 = 0,
    /// It is being typed into.
    active: u8 = 0,
    /// The keymap the keys are read through, or null for the default.
    key_map: ?*const km.KeyMap = null,
    /// Four pens: text and ground, then the two while it is active. Null
    /// takes the screen's.
    pens: ?[*]const graphics.Pen = null,
    active_pens: ?[*]const graphics.Pen = null,
    /// `STRINGA_Font`: the font the text is drawn in, which the caller
    /// keeps open; null takes the RastPort's.
    font: ?*graphics.TextFont = null,
};

/// Make strgclass, from gadgetclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.STRGCLASS, classusr.GADGETCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

fn own(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

fn textLen(s: [*]const u8, max: u32) u32 {
    var n: u32 = 0;
    while (n < max and s[n] != 0) n += 1;
    return n;
}

/// The text as a number, which a gadget holding one is read by.
fn numberOf(s: [*]const u8, len: u32) i32 {
    var i: u32 = 0;
    var negative = false;
    if (len > 0 and (s[0] == '-' or s[0] == '+')) {
        negative = s[0] == '-';
        i = 1;
    }
    var value: i64 = 0;
    while (i < len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        value = value * 10 + (s[i] - '0');
        if (value > 0x7FFFFFFF) {
            value = 0x7FFFFFFF;
            break;
        }
    }
    return @intCast(if (negative) -value else value);
}

/// Everything that follows from the text having changed.
fn textChanged(p: *Data) void {
    const buffer = p.buffer orelse return;
    p.num_chars = textLen(buffer, p.max_chars);
    p.buffer_pos = @min(p.buffer_pos, p.num_chars);
    p.long_val = numberOf(buffer, p.num_chars);
}

/// How many characters fit in the box, and which is the first shown, so
/// that the cursor is always one of them.
fn scrollTo(p: *Data, room: u32) void {
    if (room == 0) return;
    if (p.buffer_pos < p.disp_pos) p.disp_pos = p.buffer_pos;
    if (p.buffer_pos >= p.disp_pos + room) p.disp_pos = p.buffer_pos - room + 1;
    if (p.disp_pos > p.num_chars) p.disp_pos = p.num_chars;
}

// --- the default edit ------------------------------------------------------------

/// Raw keys the edit reads as they are: they make no one character.
const raw_left = 0x4F;
const raw_right = 0x4E;
const raw_home = 0x70;
const raw_end = 0x71;
const raw_delete = 0x46;
const raw_help = 0x5F;

/// A character in at the cursor, or over the one there; false when there is
/// no room, or a fixed field has none to replace.
fn workPut(w: *sg.SGWork, c: u8) bool {
    const replacing = w.modes & (sg.SGM_REPLACE | sg.SGM_FIXEDFIELD) != 0;
    if (replacing and w.buffer_pos < w.num_chars) {
        w.work_buffer[w.buffer_pos] = c;
        w.buffer_pos += 1;
        w.edit_op = sg.EO_REPLACECHAR;
        return true;
    }
    if (w.modes & sg.SGM_FIXEDFIELD != 0) return false;
    if (w.num_chars + 1 >= w.max_chars) return false;
    var i = w.num_chars;
    while (i > w.buffer_pos) : (i -= 1) w.work_buffer[i] = w.work_buffer[i - 1];
    w.work_buffer[w.buffer_pos] = c;
    w.num_chars += 1;
    w.work_buffer[w.num_chars] = 0;
    w.buffer_pos += 1;
    w.edit_op = sg.EO_INSERTCHAR;
    return true;
}

/// The character at `at` taken out.
fn workTake(w: *sg.SGWork, at: u32) void {
    if (at >= w.num_chars) return;
    var i = at;
    while (i < w.num_chars) : (i += 1) w.work_buffer[i] = w.work_buffer[i + 1];
    w.num_chars -= 1;
}

/// Intuition's own editing: the global edit hook until `SetEditHook` puts
/// another. It edits the work for `SGH_KEY` and answers 0 for anything
/// else. What the keys do: the cursor keys, Home and End move; Backspace
/// and Delete take a character out; a character goes in, or over the one
/// at the cursor in replace mode; Return ends the gadget, Tab ends it and
/// moves on (Shift-Tab back), Escape puts back what was there when it was
/// activated and ends it; Help ends it in `SGM_EXITHELP`. A fixed field
/// keeps its length: characters only replace, Backspace only moves back.
pub fn defaultEdit(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = hook;
    const w: *sg.SGWork = @ptrCast(@alignCast(object orelse return 0));
    const command: *const u32 = @ptrCast(@alignCast(message orelse return 0));
    if (command.* != sg.SGH_KEY) return 0;
    const e = w.event;
    const fixed = w.modes & sg.SGM_FIXEDFIELD != 0;
    w.edit_op = sg.EO_NOOP;
    switch (e.code) {
        raw_left, raw_right, raw_home, raw_end => {
            w.buffer_pos = switch (e.code) {
                raw_left => w.buffer_pos -| 1,
                raw_right => @min(w.buffer_pos + 1, w.num_chars),
                raw_home => 0,
                else => w.num_chars,
            };
            w.edit_op = sg.EO_MOVECURSOR;
            w.actions |= sg.SGA_REDISPLAY;
            return 1;
        },
        raw_delete => {
            if (fixed or w.buffer_pos >= w.num_chars) return 1;
            workTake(w, w.buffer_pos);
            w.edit_op = sg.EO_DELFORWARD;
            return 1;
        },
        raw_help => {
            if (w.modes & sg.SGM_EXITHELP == 0) return 1;
            w.code = raw_help;
            w.actions |= sg.SGA_END;
            return 1;
        },
        else => {},
    }
    const c = w.code;
    if (c == 0) return 1;
    switch (c) {
        0x0D, 0x0A => {
            w.edit_op = sg.EO_ENTER;
            w.code = e.code;
            w.actions |= sg.SGA_END;
        },
        0x1B => {
            // Back to what it was when it was activated.
            var i: u32 = 0;
            while (i + 1 < w.max_chars and w.undo_buffer[i] != 0) : (i += 1) w.work_buffer[i] = w.undo_buffer[i];
            w.work_buffer[i] = 0;
            w.num_chars = i;
            w.buffer_pos = @min(w.buffer_pos, i);
            w.edit_op = sg.EO_RESET;
            w.code = e.code;
            w.actions |= sg.SGA_END;
        },
        0x09 => {
            // Tab finishes the field and hands the keyboard on, rather than
            // going into the text: a tab in a line of text is not a
            // character anybody wants there.
            const back = e.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
            w.code = e.code;
            w.actions |= sg.SGA_END | (if (back) sg.SGA_PREVACTIVE else sg.SGA_NEXTACTIVE);
        },
        0x08 => {
            if (w.buffer_pos == 0) return 1;
            w.buffer_pos -= 1;
            if (fixed) {
                w.edit_op = sg.EO_MOVECURSOR;
                w.actions |= sg.SGA_REDISPLAY;
            } else {
                workTake(w, w.buffer_pos);
                w.edit_op = sg.EO_DELBACKWARD;
            }
        },
        0x7F => {
            if (fixed or w.buffer_pos >= w.num_chars) return 1;
            workTake(w, w.buffer_pos);
            w.edit_op = sg.EO_DELFORWARD;
        },
        else => {
            if (c < 0x20 and w.modes & sg.SGM_NOFILTER == 0) return 1;
            if (!workPut(w, @truncate(c))) w.actions |= sg.SGA_BEEP;
        },
    }
    w.long_int = numberOf(w.work_buffer, w.num_chars);
    return 1;
}

/// An edit in progress, for the gadget: its text in the work buffer.
fn startWork(o: *Object, p: *Data, e: *const ie.InputEvent, code: u32, gi: ?*classusr.GadgetInfo) ?sg.SGWork {
    const buffer = p.buffer orelse return null;
    const work = p.work orelse return null;
    var i: u32 = 0;
    while (i < p.num_chars) : (i += 1) work[i] = buffer[i];
    work[p.num_chars] = 0;
    return .{
        .gadget = o,
        .work_buffer = work,
        .prev_buffer = buffer,
        .undo_buffer = p.undo orelse buffer,
        .max_chars = p.max_chars,
        .modes = p.modes,
        .event = e,
        .code = code,
        .buffer_pos = p.buffer_pos,
        .num_chars = p.num_chars,
        .actions = sg.SGA_USE,
        .long_int = p.long_val,
        .gadget_info = gi,
        .edit_op = sg.EO_NOOP,
    };
}

/// The work taken as the text, if the edit said to use it; true when the
/// text or the cursor changed.
fn useWork(p: *Data, w: *const sg.SGWork) bool {
    if (w.actions & sg.SGA_USE == 0) return false;
    const buffer = p.buffer orelse return false;
    var changed = w.buffer_pos != p.buffer_pos or w.num_chars != p.num_chars;
    var i: u32 = 0;
    while (i <= w.num_chars and i < p.max_chars) : (i += 1) {
        if (buffer[i] != w.work_buffer[i]) changed = true;
        buffer[i] = w.work_buffer[i];
    }
    buffer[@min(w.num_chars, p.max_chars - 1)] = 0;
    p.buffer_pos = w.buffer_pos;
    textChanged(p);
    return changed;
}

fn boxOf(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) _gadget.Box {
    const g = gadgetclass.gadgetOf(ib, o);
    if (gi) |info| return _gadget.boxIn(g, info.domain_width, info.domain_height);
    return .{ .left = 0, .top = 0, .width = g.width, .height = g.height };
}

fn render(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, rp: *graphics.RastPort) void {
    const gi_ = gi orelse return;
    const gb = ib.graphics_base;
    const p = own(cl, o);
    const b = boxOf(ib, o, gi);
    const screen_pens = gi_.draw_info.pens;
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    // Drawn last, over everything the gadget shows, whichever way it ends.
    const disabled = gadgetclass.gadgetOf(ib, o).flags & gadgetclass.GFLG_DISABLED != 0;
    defer if (disabled) d.ghost(gb, rp, b.left, b.top, b.width, b.height, gi_.block_pen);

    const chosen = if (p.active != 0) p.active_pens orelse p.pens else p.pens;
    const ink = if (chosen) |set| set[0] else screen_pens[sc.TEXTPEN];
    const paper = if (chosen) |set| set[1] else if (p.active != 0) screen_pens[sc.FILLPEN] else screen_pens[sc.BACKGROUNDPEN];

    // A sunk frame with the text in it: the box a line is typed into.
    d.box(gb, rp, b.left, b.top, b.width, b.height, paper);
    d.bevel(gb, rp, b.left, b.top, b.width, b.height, screen_pens[sc.SHADOWPEN], screen_pens[sc.SHINEPEN], 1, .none);

    const buffer = p.buffer orelse return;
    // The gadget's own font if it has one, otherwise the RastPort's; and
    // a box too short for it takes the 8-row ROM font instead, so the
    // text stays inside the frame rather than spilling over it.
    if (p.font) |font| graphics.SetFont(gb, rp, font);
    var width: u32 = 0;
    var height: u32 = 0;
    var baseline: u32 = 0;
    const metric = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontWidth, .data = @intFromPtr(&width) },
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) },
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{},
    };
    gb.GetRPAttrs(rp, &metric);
    const small = if (b.height < @as(i32, @intCast(height))) gb.OpenFont(graphics.POSPAZNAME, 8) else null;
    defer if (small) |font| gb.CloseFont(font);
    if (small) |font| {
        graphics.SetFont(gb, rp, font);
        gb.GetRPAttrs(rp, &metric);
    }
    if (width == 0 or height == 0) return;
    const inner_w = b.width - 4;
    const room: u32 = @intCast(@max(@divTrunc(inner_w, @as(i32, @intCast(width))), 1));
    scrollTo(p, room);
    const shown = @min(room, p.num_chars - p.disp_pos);

    // Where the line sits in the box. The cursor takes a cell of its own
    // when it sits past the last character shown, and that cell is part of
    // what is being placed - otherwise a line pushed against the right edge
    // would put its cursor on the frame, outside the field it belongs to.
    // `scrollTo` keeps the cursor within `room`, so the line and the cell
    // together never come to more than the field holds.
    const caret: u32 = if (p.active != 0 and p.buffer_pos - p.disp_pos >= shown) 1 else 0;
    const text_w: i32 = @intCast((shown + caret) * width);
    const left = switch (p.justification) {
        gc.GACT_STRINGCENTER => b.left + 2 + @divTrunc(inner_w - text_w, 2),
        gc.GACT_STRINGRIGHT => b.left + 2 + inner_w - text_w,
        else => b.left + 2,
    };
    const top = b.top + @divTrunc(b.height - @as(i32, @intCast(height)), 2);

    if (shown > 0) {
        d.pen(gb, rp, ink);
        gb.Move(rp, left, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, buffer + p.disp_pos, shown);
    }
    // The cursor, while it is being typed into: the cell the next
    // character goes in, the other way round.
    if (p.active == 0) return;
    const at = p.buffer_pos - p.disp_pos;
    const cursor_x = left + @as(i32, @intCast(at * width));
    d.box(gb, rp, cursor_x, top, @intCast(width), @intCast(height), ink);
    if (p.buffer_pos < p.num_chars) {
        d.pen(gb, rp, paper);
        gb.Move(rp, cursor_x, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, buffer + p.buffer_pos, 1);
    }
}

fn redraw(ib: *IntuitionBase, o: *Object, gi: ?*classusr.GadgetInfo) void {
    const it = ib.iface();
    const rp = it.ObtainGIRPort(gi) orelse return;
    defer it.ReleaseGIRPort(rp);
    var msg = gc.GpRender{ .gadget_info = gi, .rast_port = rp, .redraw = gc.GREDRAW_UPDATE };
    _ = it.SendMessage(o, @ptrCast(&msg));
}

/// The target told what the text says now.
fn tell(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, flags: u32) void {
    const p = own(cl, o);
    // Its ID, so that a program with two fields can tell which one it is.
    const tags = [_]TagItem{
        .{ .tag = gc.GA_ID, .data = gadgetclass.gadgetOf(ib, o).id },
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr(p.buffer) },
        .{ .tag = gc.STRINGA_LongVal, .data = @bitCast(@as(isize, p.long_val)) },
        .{},
    };
    var msg = classusr.OpUpdate{ .method_id = classusr.OM_NOTIFY, .attr_list = &tags, .gadget_info = gi, .flags = flags };
    _ = ib.iface().SendMessage(o, @ptrCast(&msg));
}

/// What was there when it was activated, kept so Escape can put it back.
fn keepUndo(p: *Data) void {
    const buffer = p.buffer orelse return;
    const undo = p.undo orelse return;
    var i: u32 = 0;
    while (i < p.num_chars) : (i += 1) undo[i] = buffer[i];
    undo[p.num_chars] = 0;
}

fn restoreUndo(p: *Data) void {
    const buffer = p.buffer orelse return;
    const undo = p.undo orelse return;
    var i: u32 = 0;
    while (i + 1 < p.max_chars and undo[i] != 0) : (i += 1) buffer[i] = undo[i];
    buffer[i] = 0;
    textChanged(p);
}

fn takeTags(ib: *IntuitionBase, p: *Data, tags: ?[*]const TagItem, at_birth: bool) bool {
    var changed = false;
    var state = tags;
    while (ib.utility_base.NextTagItem(&state)) |item| {
        switch (item.tag) {
            // At birth only, as the buffer is: the buffer and the undo room
            // were allocated for this many, and more would write past them.
            gc.STRINGA_MaxChars => if (at_birth) {
                p.max_chars = @max(@as(u32, @truncate(item.data)), 2);
                changed = true;
            },
            // A buffer is given when the gadget is made and not after:
            // `at_birth` is false for every later set. Swapping it later
            // would leave whatever the gadget allocated for itself with
            // nothing pointing at it, and the undo room pointing into it.
            gc.STRINGA_Buffer, gc.STRINGA_TextVal => {
                if (item.tag == gc.STRINGA_Buffer and item.data != 0) {
                    if (!at_birth) continue;
                    p.buffer = @ptrFromInt(item.data);
                    p.owns_buffer = 0;
                } else if (item.tag == gc.STRINGA_TextVal and item.data != 0) {
                    // The text itself, copied into whatever buffer there is.
                    const from: [*:0]const u8 = @ptrFromInt(item.data);
                    const into = p.buffer orelse continue;
                    var i: u32 = 0;
                    while (i + 1 < p.max_chars and from[i] != 0) : (i += 1) into[i] = from[i];
                    into[i] = 0;
                    p.buffer_pos = 0;
                    p.disp_pos = 0;
                }
                textChanged(p);
                changed = true;
            },
            gc.STRINGA_UndoBuffer => {
                // Nothing there is not an instruction to go without: a
                // gadget that cannot put back what was typed over is a
                // gadget whose Escape key does nothing, silently.
                if (at_birth and item.data != 0) {
                    p.undo = @ptrFromInt(item.data);
                    p.owns_undo = 0;
                    changed = true;
                }
            },
            gc.STRINGA_BufferPos => {
                p.buffer_pos = @min(@as(u32, @truncate(item.data)), p.num_chars);
                changed = true;
            },
            gc.STRINGA_DispPos => {
                p.disp_pos = @truncate(item.data);
                changed = true;
            },
            gc.STRINGA_AltKeyMap => {
                p.key_map = @ptrFromInt(item.data);
            },
            gc.STRINGA_Pens => {
                p.pens = @ptrFromInt(item.data);
                changed = true;
            },
            gc.STRINGA_ActivePens => {
                p.active_pens = @ptrFromInt(item.data);
                changed = true;
            },
            gc.STRINGA_Font => {
                p.font = @ptrFromInt(item.data);
                changed = true;
            },
            gc.STRINGA_ReplaceMode => setMode(p, sg.SGM_REPLACE, item.data != 0),
            gc.STRINGA_FixedFieldMode => setMode(p, sg.SGM_FIXEDFIELD | sg.SGM_REPLACE, item.data != 0),
            gc.STRINGA_NoFilterMode => setMode(p, sg.SGM_NOFILTER, item.data != 0),
            gc.STRINGA_ExitHelp => setMode(p, sg.SGM_EXITHELP, item.data != 0),
            gc.STRINGA_EditModes => p.modes = @truncate(item.data),
            gc.STRINGA_EditHook => p.edit_hook = @ptrFromInt(item.data),
            // At birth only, as the buffer is.
            gc.STRINGA_WorkBuffer => if (at_birth and item.data != 0) {
                p.work = @ptrFromInt(item.data);
                p.owns_work = 0;
            },
            gc.STRINGA_Justification => {
                p.justification = @truncate(item.data);
                changed = true;
            },
            gc.STRINGA_LongVal => {
                // A number written into the text, so that both say the same.
                const into = p.buffer orelse continue;
                const value: i32 = @truncate(@as(isize, @bitCast(item.data)));
                var digits: [12]u8 = undefined;
                var n: u32 = 0;
                const negative = value < 0;
                var left: u64 = if (negative) @intCast(-@as(i64, value)) else @intCast(value);
                if (left == 0) {
                    digits[0] = '0';
                    n = 1;
                }
                while (left > 0) : (left /= 10) {
                    digits[n] = '0' + @as(u8, @intCast(left % 10));
                    n += 1;
                }
                var at: u32 = 0;
                if (negative and at + 1 < p.max_chars) {
                    into[at] = '-';
                    at += 1;
                }
                while (n > 0 and at + 1 < p.max_chars) {
                    n -= 1;
                    into[at] = digits[n];
                    at += 1;
                }
                into[at] = 0;
                p.buffer_pos = 0;
                textChanged(p);
                changed = true;
            },
            else => {},
        }
    }
    return changed;
}

/// The cursor moved to the character a press landed on. The field scrolls,
/// so what is under the pointer is `disp_pos` characters along from the
/// start of the text, not from the start of the buffer.
fn cursorTo(ib: *IntuitionBase, p: *Data, gi: ?*classusr.GadgetInfo, x: i32) void {
    const it = ib.iface();
    var width: u32 = 0;
    if (it.ObtainGIRPort(gi)) |port| {
        const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontWidth, .data = @intFromPtr(&width) }, .{} };
        ib.graphics_base.GetRPAttrs(port, &metric);
        it.ReleaseGIRPort(port);
    }
    if (width == 0) return;
    const at = @divTrunc(x - 2, @as(i32, @intCast(width)));
    p.buffer_pos = @min(p.disp_pos + @as(u32, @intCast(@max(at, 0))), p.num_chars);
}

fn setMode(p: *Data, bits: u32, on: bool) void {
    if (on) p.modes |= bits else p.modes &= ~bits;
}

/// What the gadget allocated for itself, given back.
fn freeOwn(ib: *IntuitionBase, p: *Data) void {
    if (p.owns_buffer != 0) {
        if (p.buffer) |b| ib.sys_base.FreeVec(b);
    }
    if (p.owns_undo != 0) {
        if (p.undo) |u| ib.sys_base.FreeVec(u);
    }
    if (p.owns_work != 0) {
        if (p.work) |w| ib.sys_base.FreeVec(w);
    }
    p.buffer = null;
    p.undo = null;
    p.work = null;
}

/// A key edited: the global hook and then the gadget's own on the work,
/// and what they asked for done.
fn editKey(ib: *IntuitionBase, cl: *Class, o: *Object, p: *Data, in: *gc.GpInput, e: *const ie.InputEvent) usize {
    var code: u32 = 0;
    if (ib.keymap_base) |kb| {
        var text: [16]u8 = undefined;
        if (kb.MapRawKey(e, &text, text.len, p.key_map) == 1) code = text[0];
    }
    var w = startWork(o, p, e, code, in.gadget_info) orelse return gc.GMR_MEACTIVE;
    var command: u32 = sg.SGH_KEY;
    const ub = ib.utility_base;
    _ = ub.CallHookPkt(ib.edit_hook, &w, &command);
    if (p.edit_hook) |hook| _ = ub.CallHookPkt(hook, &w, &command);

    const changed = useWork(p, &w);
    if (w.actions & sg.SGA_BEEP != 0) {
        if (in.gadget_info) |gi| ib.iface().DisplayBeep(gi.screen);
    }
    if (w.actions & sg.SGA_END != 0) {
        p.active = 0;
        redraw(ib, o, in.gadget_info);
        tell(ib, cl, o, in.gadget_info, 0);
        in.termination.* = @bitCast(w.code);
        if (w.actions & sg.SGA_PREVACTIVE != 0) return gc.GMR_PREVACTIVE;
        if (w.actions & sg.SGA_NEXTACTIVE != 0) return gc.GMR_NEXTACTIVE;
        const reuse: usize = if (w.actions & sg.SGA_REUSE != 0) gc.GMR_REUSE else gc.GMR_NOREUSE;
        return reuse | gc.GMR_VERIFY;
    }
    if (changed or w.actions & sg.SGA_REDISPLAY != 0) redraw(ib, o, in.gadget_info);
    if (changed) tell(ib, cl, o, in.gadget_info, classusr.OPUF_INTERIM);
    return gc.GMR_MEACTIVE;
}

/// A press has put the cursor where it landed: the gadget's own hook may
/// put it elsewhere.
fn clickHook(ib: *IntuitionBase, o: *Object, p: *Data, e: ?*const ie.InputEvent, gi: ?*classusr.GadgetInfo) void {
    const hook = p.edit_hook orelse return;
    const event = e orelse return;
    var w = startWork(o, p, event, 0, gi) orelse return;
    var command: u32 = sg.SGH_CLICK;
    if (ib.utility_base.CallHookPkt(hook, &w, &command) == 0) return;
    if (w.actions & sg.SGA_USE != 0) p.buffer_pos = @min(w.buffer_pos, p.num_chars);
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const ib: *IntuitionBase = @ptrFromInt(cl.user_data);
    const it = ib.iface();
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = it.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const p = own(cl, obj);
            p.* = .{};
            _ = takeTags(ib, p, set.attr_list, true);

            // Given up on through the superclass, not through this object's
            // own class: its instance data is half set up, and its own
            // disposal would read what it has not finished writing.
            var gone = classusr.Msg{ .method_id = classusr.OM_DISPOSE };

            // Told how much room but given none: it takes its own, so that
            // one call is enough to have a gadget that can be typed into.
            if (p.buffer == null) {
                const memory = ib.sys_base.AllocVec(p.max_chars, sdk.exec.MEMF_ANY | sdk.exec.MEMF_CLEAR) orelse {
                    _ = it.SendSuperMessage(cl, obj, &gone);
                    return 0;
                };
                p.buffer = @ptrCast(memory);
                p.owns_buffer = 1;
                // The text a tag list gave before there was a buffer.
                _ = takeTags(ib, p, set.attr_list, true);
            }

            // Somewhere to keep what was there, so Escape can put it back.
            // A gadget given a buffer to edit is rarely given this as well,
            // and without it the key does nothing at all.
            if (p.undo == null) {
                const memory = ib.sys_base.AllocVec(p.max_chars, sdk.exec.MEMF_ANY | sdk.exec.MEMF_CLEAR) orelse {
                    if (p.owns_buffer != 0) {
                        if (p.buffer) |b| ib.sys_base.FreeVec(b);
                        p.buffer = null;
                    }
                    _ = it.SendSuperMessage(cl, obj, &gone);
                    return 0;
                };
                p.undo = @ptrCast(memory);
                p.owns_undo = 1;
            }
            // And the room a key is edited in before it counts.
            if (p.work == null) {
                const memory = ib.sys_base.AllocVec(p.max_chars, sdk.exec.MEMF_ANY | sdk.exec.MEMF_CLEAR) orelse {
                    freeOwn(ib, p);
                    _ = it.SendSuperMessage(cl, obj, &gone);
                    return 0;
                };
                p.work = @ptrCast(memory);
                p.owns_work = 1;
            }
            textChanged(p);
            return made;
        },
        classusr.OM_DISPOSE => {
            freeOwn(ib, own(cl, o orelse return 0));
            return it.SendSuperMessage(cl, o, msg);
        },
        classusr.OM_SET, classusr.OM_UPDATE => {
            const changed = it.SendSuperMessage(cl, o, msg);
            const set: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const mine = takeTags(ib, own(cl, o.?), set.attr_list, false);
            if ((changed != 0 or mine) and classes.objectClass(o.?) == cl and set.gadget_info != null) {
                redraw(ib, o.?, set.gadget_info);
                return 0;
            }
            return if (mine) 1 else changed;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            switch (get.attr_id) {
                gc.STRINGA_Buffer, gc.STRINGA_TextVal => get.storage.* = @intFromPtr(p.buffer),
                gc.STRINGA_UndoBuffer => get.storage.* = @intFromPtr(p.undo),
                gc.STRINGA_MaxChars => get.storage.* = p.max_chars,
                gc.STRINGA_BufferPos => get.storage.* = p.buffer_pos,
                gc.STRINGA_DispPos => get.storage.* = p.disp_pos,
                gc.STRINGA_LongVal => get.storage.* = @bitCast(@as(isize, p.long_val)),
                gc.STRINGA_Justification => get.storage.* = p.justification,
                gc.STRINGA_ReplaceMode => get.storage.* = @intFromBool(p.modes & sg.SGM_REPLACE != 0),
                gc.STRINGA_FixedFieldMode => get.storage.* = @intFromBool(p.modes & sg.SGM_FIXEDFIELD != 0),
                gc.STRINGA_NoFilterMode => get.storage.* = @intFromBool(p.modes & sg.SGM_NOFILTER != 0),
                gc.STRINGA_ExitHelp => get.storage.* = @intFromBool(p.modes & sg.SGM_EXITHELP != 0),
                gc.STRINGA_EditModes => get.storage.* = p.modes,
                gc.STRINGA_EditHook => get.storage.* = @intFromPtr(p.edit_hook),
                gc.STRINGA_WorkBuffer => get.storage.* = @intFromPtr(p.work),
                gc.STRINGA_Font => get.storage.* = @intFromPtr(p.font),
                else => return it.SendSuperMessage(cl, o, msg),
            }
            return 1;
        },
        gc.GM_HITTEST => {
            const ht: *gc.GpHitTest = @ptrCast(@alignCast(msg));
            const b = boxOf(ib, o.?, ht.gadget_info);
            return if (ht.mouse.x >= 0 and ht.mouse.y >= 0 and ht.mouse.x < b.width and ht.mouse.y < b.height) gc.GMR_GADGETHIT else 0;
        },
        gc.GM_RENDER => {
            const r: *gc.GpRender = @ptrCast(@alignCast(msg));
            render(ib, cl, o.?, r.gadget_info, r.rast_port);
            return 0;
        },
        gc.GM_GOACTIVE => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            if (p.buffer == null) return gc.GMR_NOREUSE;
            p.active = 1;
            keepUndo(p);
            // A press puts the cursor where it landed; being activated
            // without one leaves it where it was.
            if (in.event != null and in.mouse.x >= 0) {
                cursorTo(ib, p, in.gadget_info, in.mouse.x);
                clickHook(ib, o.?, p, in.event, in.gadget_info);
            }
            redraw(ib, o.?, in.gadget_info);
            return gc.GMR_MEACTIVE;
        },
        gc.GM_HANDLEINPUT => {
            const in: *gc.GpInput = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            const e = in.event orelse return gc.GMR_MEACTIVE;
            // A press somewhere else ends it, as it does on any gadget.
            if (e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_LBUTTON) {
                const b = boxOf(ib, o.?, in.gadget_info);
                if (in.mouse.x < 0 or in.mouse.y < 0 or in.mouse.x >= b.width or in.mouse.y >= b.height) {
                    p.active = 0;
                    redraw(ib, o.?, in.gadget_info);
                    tell(ib, cl, o.?, in.gadget_info, 0);
                    // Done with it, and the press belongs to whatever was
                    // under it: one of these two, never both.
                    return gc.GMR_REUSE;
                }
                // Pressed again inside itself: the cursor goes where the
                // pointer is, which is what a press in a line of text means.
                cursorTo(ib, p, in.gadget_info, in.mouse.x);
                clickHook(ib, o.?, p, e, in.gadget_info);
                redraw(ib, o.?, in.gadget_info);
                return gc.GMR_MEACTIVE;
            }
            if (e.class != ie.IECLASS_RAWKEY) return gc.GMR_MEACTIVE;
            if (e.code & ie.IECODE_UP_PREFIX != 0) return gc.GMR_MEACTIVE;
            return editKey(ib, cl, o.?, p, in, e);
        },
        gc.GM_GOINACTIVE => {
            const gi: *gc.GpGoInactive = @ptrCast(@alignCast(msg));
            const p = own(cl, o.?);
            if (p.active != 0) {
                p.active = 0;
                redraw(ib, o.?, gi.gadget_info);
            }
            return 0;
        },
        else => return it.SendSuperMessage(cl, o, msg),
    }
}
