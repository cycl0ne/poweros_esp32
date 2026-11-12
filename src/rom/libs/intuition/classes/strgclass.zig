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
//! **The text is UTF-8.** The buffer, its length and the cursor are
//! counted in bytes - `STRINGA_MaxChars` is the room in bytes - and the
//! cursor always stands where a character starts: it steps over a
//! cluster (`utility.unicode.clusterEnd`) - a letter with its marks, a
//! syllable whose consonants a virama joins, a sequence a joiner holds
//! together - Delete takes a cluster out and Backspace one character,
//! the one last typed and not the cluster it belongs to, and a
//! character goes in only when all of its bytes fit. A key that sends
//! several characters has them go in one after the other, each as if
//! it were typed, and all of them or none. A byte that is no UTF-8 is
//! a character of its own, as graphics draws it.
//!
//! **The cursor is where the letters are drawn.** The line shown is
//! drawn in one piece, and the cursor's place and width and the
//! character a press lands on are asked of graphics for that piece
//! (`TextOffsetToX`, `TextXToOffset`) - so with a font that shapes its
//! text a kerned pair is where it was drawn, and the cursor on a letter
//! covers the letter with its marks.
//!
//! `STRINGA_Secret` makes it a password field: an asterisk is drawn for
//! each character of the text, and where the line scrolls to and what a
//! press lands on are measured on those asterisks rather than on the
//! characters they stand for - the positions in the buffer turned into
//! positions among the asterisks and back. The buffer holds what was
//! typed as it always does.
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
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gc = intuition.gadgetclass;
const sg = intuition.sghooks;
const sc = intuition.screens;
const ie = sdk.devices.inputevent;
const km = sdk.keymap;
const utf8 = utility.utf8;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const style = intuition.style;
const ic = intuition.imageclass;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const gadgetclass = @import("gadgetclass.zig");
const _transition = @import("../style/_transition.zig");
const _gadget = @import("../gadget/_gadget.zig");
const d = @import("draw.zig");

/// strgclass's part of an object.
pub const Data = extern struct {
    /// What is being typed into, and how much room it has in bytes.
    buffer: ?[*]u8 = null,
    undo: ?[*]u8 = null,
    max_chars: u32 = gc.SG_DEFAULTMAXCHARS,
    /// Where the cursor is and which character is shown first, and the
    /// text's length: bytes into the buffer, each where a character
    /// starts.
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
    /// How many bytes of the text drawn the last drawing showed - of the
    /// asterisks, while it is secret - and how far in from the box's left
    /// edge the text began: where a press is measured from.
    disp_count: u32 = 0,
    text_left: i32 = 2,
    /// `STRINGA_Secret`: what is typed is not shown.
    secret: u8 = 0,
    /// What is drawn in its place while it is secret, a `mask_char` for
    /// each character the buffer holds: the gadget's own, taken when it
    /// is first drawn.
    mask: ?[*]u8 = null,
};

/// What a secret field shows for each character of its text.
const mask_char: u8 = '*';

/// Make strgclass, from gadgetclass, and put it on the public list.
pub fn make(ib: *IntuitionBase) ?*Class {
    const it = ib.iface();
    const cl = it.MakeClass(classusr.STRGCLASS, classusr.GADGETCLASS, null, @sizeOf(Data)) orelse return null;
    cl.dispatcher.entry = &dispatch;
    cl.user_data = @intFromPtr(ib);
    it.AddClass(cl);
    return cl;
}

/// How many characters wide a line is at the least: enough to see what is
/// being typed.
const least_chars = 4;

/// Its size, for `GM_DOMAIN`: one line of its font high inside its frame,
/// never taller - a line of text has no use for more - and at least a few
/// characters wide; the width it was given as it looks right, and as wide
/// as there is room at the most.
fn domain(ib: *IntuitionBase, cl: *Class, o: *Object, gi: ?*classusr.GadgetInfo, which: u32) gc.Box {
    const g = gadgetclass.gadgetOf(ib, o);
    const p = own(cl, o);
    const measure: gadgetclass.Measure = if (p.font) |font| .{ .font = font, .opened = false } else gadgetclass.measureFont(ib, g, gi);
    defer measure.done(ib);
    const cell = gadgetclass.fontCell(ib, measure.font);
    // The frame and the gap inside it: two pixels a side, as it is drawn.
    const height = cell.height + 4;
    const least = least_chars * cell.width + 4;
    return switch (which) {
        gc.GDOMAIN_MINIMUM => .{ .width = least, .height = height },
        gc.GDOMAIN_NOMINAL => .{ .width = @max(least, g.given_width), .height = height },
        else => .{ .width = gc.GDOMAIN_UNLIMITED, .height = height },
    };
}

fn own(cl: *Class, o: *Object) *Data {
    return classes.instData(Data, cl, o);
}

fn textLen(s: [*]const u8, max: u32) u32 {
    var n: u32 = 0;
    while (n < max and s[n] != 0) n += 1;
    return n;
}

/// The bytes the character at `at` of `text` (`len` bytes, `at` before
/// its end) takes.
fn charLength(text: [*]const u8, len: u32, at: u32) u32 {
    return @intCast(utf8.read(text[at..len]).length);
}

/// The bytes the cluster at `at` of `text` (`len` bytes, `at` before
/// its end) takes: the character there with what Unicode keeps with it,
/// which is what the cursor covers.
fn clusterLength(text: [*]const u8, len: u32, at: u32) u32 {
    return @intCast(utility.unicode.clusterEnd(text[0..len], at) - at);
}

/// Where the character before `at` (above 0) starts.
fn charBefore(text: [*]const u8, at: u32) u32 {
    return at - @as(u32, @intCast(utf8.readLast(text[0..at]).length));
}

/// Where the cluster before `at` (above 0) starts: the one the last
/// byte before `at` is in.
fn clusterBefore(text: [*]const u8, at: u32) u32 {
    return @intCast(utility.unicode.clusterStart(text[0..at], at - 1));
}

/// How many characters the first `len` bytes of `text` hold.
fn charCount(text: [*]const u8, len: u32) u32 {
    var count: u32 = 0;
    var at: u32 = 0;
    while (at < len) : (count += 1) at += charLength(text, len, at);
    return count;
}

/// Where the `index`th character of `text` (`len` bytes) starts, or `len`
/// past its last.
fn charStart(text: [*]const u8, len: u32, index: u32) u32 {
    var at: u32 = 0;
    var left = index;
    while (left > 0 and at < len) : (left -= 1) at += charLength(text, len, at);
    return at;
}

/// `from` copied into `into`, as much as fits in `max` bytes with the NUL
/// and without ending inside a character; its length.
fn copyText(into: [*]u8, from: [*]const u8, max: u32) u32 {
    const len = textLen(from, max);
    const kept: u32 = @intCast(utf8.cut(from[0..len], max -| 1));
    var i: u32 = 0;
    while (i < kept) : (i += 1) into[i] = from[i];
    into[kept] = 0;
    return kept;
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

/// The tallest a line is measured against: TextFit asks for a height too.
const any_height = 0x7FFF;

/// The text as it is drawn and measured: the buffer itself, or an
/// asterisk for each of its characters while the field is secret. Its
/// length, its cursor and its first shown byte, in its own bytes.
const Shown = struct {
    text: [*]const u8,
    len: u32,
    cursor: u32,
    first: u32,
};

/// Which byte of the text drawn is shown first, kept in `view.first`, and
/// how many are, in `room` pixels, so that the cursor is always among
/// them, measured in the RastPort's font a character at a time: a
/// proportional font's narrow letters let more of the line show than its
/// widest would. `extra` is kept free at the right for the cursor when it
/// stands past the last character.
fn scrollTo(gb: *GraphicsBase, rp: *graphics.RastPort, view: *Shown, room: i32, extra: i32) u32 {
    var te: graphics.TextExtent = undefined;
    const avail = @max(room - extra, 1);
    const text = view.text;
    const len = view.len;
    if (len == 0) {
        view.first = 0;
        return 0;
    }
    if (view.cursor < view.first) view.first = view.cursor;
    view.first = @min(view.first, len);
    var shown = gb.TextFit(rp, text + view.first, len - view.first, &te, null, 1, avail, any_height);
    // Everything up to the cursor, and the character under it, shows.
    const needed = if (view.cursor < len) view.cursor + charLength(text, len, view.cursor) else len;
    if (view.first + shown < needed) {
        const back = gb.TextFit(rp, text + needed - 1, needed, &te, null, -1, avail, any_height);
        view.first = if (back > 0) needed - back else charBefore(text, needed);
        shown = gb.TextFit(rp, text + view.first, len - view.first, &te, null, 1, avail, any_height);
    } else if (view.first > 0 and view.first + shown >= len) {
        // Scrolled further than the end needs: as much as fits is shown.
        const back = gb.TextFit(rp, text + len - 1, len, &te, null, -1, avail, any_height);
        view.first = if (back > 0) len - back else charBefore(text, len);
        shown = len - view.first;
    }
    return shown;
}

// --- the default edit ------------------------------------------------------------

/// Raw keys the edit reads as they are: they make no one character.
/// The bytes a key may make: a syllable of four consonants joined, with
/// room to spare.
const key_room = 32;

const raw_left = 0x4F;
const raw_right = 0x4E;
const raw_home = 0x70;
const raw_end = 0x71;
const raw_delete = 0x46;
const raw_help = 0x5F;
/// The Tab key, read as a key rather than a character: shifted, the
/// keymap makes it a string (CSI Z), which is no one character.
const raw_tab = 0x42;

/// A character in at the cursor, in UTF-8, or over the one there; false
/// when its bytes do not all fit, or a fixed field has none to replace.
fn workPut(w: *sg.SGWork, c: u32) bool {
    var bytes: [4]u8 = undefined;
    const length: u32 = @intCast(utf8.encode(c, &bytes));
    const replacing = w.modes & (sg.SGM_REPLACE | sg.SGM_FIXEDFIELD) != 0;
    if (replacing and w.buffer_pos < w.num_chars) {
        const old = charLength(w.work_buffer, w.num_chars, w.buffer_pos);
        if (w.num_chars - old + length >= w.max_chars) return false;
        workTake(w, w.buffer_pos);
        workInsert(w, bytes[0..length]);
        w.edit_op = sg.EO_REPLACECHAR;
        return true;
    }
    if (w.modes & sg.SGM_FIXEDFIELD != 0) return false;
    if (w.num_chars + length >= w.max_chars) return false;
    workInsert(w, bytes[0..length]);
    w.edit_op = sg.EO_INSERTCHAR;
    return true;
}

/// `bytes` in at the cursor, which moves past them; there is room.
fn workInsert(w: *sg.SGWork, bytes: []const u8) void {
    const length: u32 = @intCast(bytes.len);
    var i = w.num_chars;
    while (i > w.buffer_pos) : (i -= 1) w.work_buffer[i - 1 + length] = w.work_buffer[i - 1];
    for (bytes, 0..) |byte, k| w.work_buffer[w.buffer_pos + k] = byte;
    w.num_chars += length;
    w.work_buffer[w.num_chars] = 0;
    w.buffer_pos += length;
}

/// The character at `at` taken out, all its bytes.
fn workTake(w: *sg.SGWork, at: u32) void {
    if (at >= w.num_chars) return;
    const length = charLength(w.work_buffer, w.num_chars, at);
    var i = at;
    while (i + length <= w.num_chars) : (i += 1) w.work_buffer[i] = w.work_buffer[i + length];
    w.num_chars -= length;
}

/// Takes the character at `at` out of the work together with the marks
/// after it.
fn workTakeCluster(w: *sg.SGWork, at: u32) void {
    if (at >= w.num_chars) return;
    const left = w.num_chars - clusterLength(w.work_buffer, w.num_chars, at);
    while (w.num_chars > left) workTake(w, at);
}

/// Intuition's own editing: the global edit hook until `SetEditHook` puts
/// another. It edits the work for `SGH_KEY` and answers 0 for anything
/// else. What the keys do: the cursor keys move a cluster at a time - a
/// letter with its marks, a syllable of joined consonants - and a cursor
/// key with Shift, Home and End go to the start or the end; Delete takes
/// a cluster out, Backspace one character, all its bytes, and
/// with Shift everything before the cursor or after it; a character goes
/// in, in UTF-8, or over the one at the cursor in replace mode; Return ends the gadget, Tab ends it and
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
    const shifted = e.qualifier & (ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT) != 0;
    w.edit_op = sg.EO_NOOP;
    switch (e.code) {
        raw_left, raw_right, raw_home, raw_end => {
            w.buffer_pos = switch (e.code) {
                raw_left => if (shifted or w.buffer_pos == 0) 0 else clusterBefore(w.work_buffer, w.buffer_pos),
                raw_right => if (shifted or w.buffer_pos >= w.num_chars) w.num_chars else w.buffer_pos + clusterLength(w.work_buffer, w.num_chars, w.buffer_pos),
                raw_home => 0,
                else => w.num_chars,
            };
            w.edit_op = sg.EO_MOVECURSOR;
            w.actions |= sg.SGA_REDISPLAY;
            return 1;
        },
        raw_delete => {
            if (fixed or w.buffer_pos >= w.num_chars) return 1;
            if (shifted) {
                w.num_chars = w.buffer_pos;
                w.work_buffer[w.num_chars] = 0;
            } else workTakeCluster(w, w.buffer_pos);
            w.edit_op = sg.EO_DELFORWARD;
            return 1;
        },
        raw_tab => {
            w.code = 0x09;
            w.actions |= sg.SGA_END | (if (shifted) sg.SGA_PREVACTIVE else sg.SGA_NEXTACTIVE);
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
            // Back to what it was when it was activated, the cursor at its
            // end - where it was may be inside a character now.
            const i = copyText(w.work_buffer, w.undo_buffer, w.max_chars);
            w.num_chars = i;
            w.buffer_pos = i;
            w.edit_op = sg.EO_RESET;
            w.code = e.code;
            w.actions |= sg.SGA_END;
        },
        0x09 => {
            // Tab finishes the field and hands the keyboard on, rather than
            // going into the text: a tab in a line of text is not a
            // character anybody wants there.
            w.code = e.code;
            w.actions |= sg.SGA_END | (if (shifted) sg.SGA_PREVACTIVE else sg.SGA_NEXTACTIVE);
        },
        0x08 => {
            if (w.buffer_pos == 0) return 1;
            const to: u32 = if (shifted) 0 else charBefore(w.work_buffer, w.buffer_pos);
            if (fixed) {
                w.buffer_pos = to;
                w.edit_op = sg.EO_MOVECURSOR;
                w.actions |= sg.SGA_REDISPLAY;
            } else {
                while (w.buffer_pos > to) {
                    w.buffer_pos = charBefore(w.work_buffer, w.buffer_pos);
                    workTake(w, w.buffer_pos);
                }
                w.edit_op = sg.EO_DELBACKWARD;
            }
        },
        0x7F => {
            if (fixed or w.buffer_pos >= w.num_chars) return 1;
            workTakeCluster(w, w.buffer_pos);
            w.edit_op = sg.EO_DELFORWARD;
        },
        else => {
            if (c < 0x20 and w.modes & sg.SGM_NOFILTER == 0) return 1;
            if (!workPut(w, c)) w.actions |= sg.SGA_BEEP;
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
    const saved = d.save(gb, rp);
    defer d.restore(gb, rp, saved);
    // Drawn last, over everything the gadget shows, whichever way it ends.
    const disabled = gadgetclass.gadgetOf(ib, o).flags & gadgetclass.GFLG_DISABLED != 0;
    defer if (disabled) gadgetclass.ghost(ib, o, gi_, rp, b.left, b.top, b.width, b.height);

    // The look is the style's `PART_FIELD`, focused while it is being
    // edited and hovered while the pointer is over it, the gadget's own
    // style asked first. Pens the gadget was given
    // for its paper and ink are its own, and win.
    const it = ib.iface();
    const own_style: ?*const intuition.Style = gadgetclass.gadgetOf(ib, o).style;
    const st = _transition.state(ib, o, gi_.draw_info, ic.PART_FIELD, (if (p.active != 0) style.STATE_FOCUSED else style.STATE_NORMAL) | gc.styleStates(gadgetclass.gadgetOf(ib, o).flags));
    const chosen = if (p.active != 0) p.active_pens orelse p.pens else p.pens;
    const ink: graphics.Pen = if (chosen) |set| set[0] else @truncate(it.GetStyleAttr(gi_.draw_info, own_style, ic.PART_FIELD, st, style.STYLE_TextPen));
    // The character under the cursor is drawn in it, the other way round.
    const paper: graphics.Pen = if (chosen) |set| set[1] else @truncate(it.GetStyleAttr(gi_.draw_info, own_style, ic.PART_FIELD, st, style.STYLE_Background));

    // A sunk frame with the text in it: the box a line is typed into.
    const field = graphics.Rect{ .min_x = b.left, .min_y = b.top, .max_x = b.left + b.width, .max_y = b.top + b.height };
    if (chosen) |set| {
        d.box(gb, rp, b.left, b.top, b.width, b.height, set[1]);
        it.DrawPart(rp, gi_.draw_info, own_style, ic.PART_FIELD, st, style.DPF_EDGES_ONLY, &field, null);
    } else {
        it.DrawPart(rp, gi_.draw_info, own_style, ic.PART_FIELD, st, style.DPF_CLEAR, &field, null);
    }

    const text = textShown(ib, p) orelse return;
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
    const small = if (b.height < @as(i32, @intCast(height))) gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 8 }) else null;
    defer if (small) |font| gb.CloseFont(font);
    if (small) |font| {
        graphics.SetFont(gb, rp, font);
        gb.GetRPAttrs(rp, &metric);
    }
    if (width == 0 or height == 0) return;
    const inner_w = b.width - 4;
    // The cursor past the last character takes a space's room of its own,
    // which is part of what is placed - otherwise a line pushed against
    // the right edge would put its cursor on the frame, outside the field.
    const space_w = gb.TextLength(rp, " ", 1);
    const past_end = p.buffer_pos >= p.num_chars;
    const extra: i32 = if (past_end) space_w else 0;
    var view = shownView(p, text);
    const shown = scrollTo(gb, rp, &view, inner_w, extra);
    p.disp_pos = bufferAt(p, view.first);
    p.disp_count = shown;

    const caret_w: i32 = if (p.active != 0 and past_end) space_w else 0;
    const text_w: i32 = gb.TextLength(rp, text + view.first, shown) + caret_w;
    const left = switch (p.justification) {
        gc.GACT_STRINGCENTER => b.left + 2 + @divTrunc(inner_w - text_w, 2),
        gc.GACT_STRINGRIGHT => b.left + 2 + inner_w - text_w,
        else => b.left + 2,
    };
    p.text_left = left - b.left;
    const top = b.top + @divTrunc(b.height - @as(i32, @intCast(height)), 2);

    if (shown > 0) {
        d.pen(gb, rp, ink);
        gb.Move(rp, left, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, text + view.first, shown);
    }
    // The cursor, while it is being typed into: the cell the next
    // character goes in, the other way round.
    // Its place and its width are those of the line as it was drawn,
    // not the lengths of its pieces added up. On a mark - the cursor
    // steps a character at a time - it is a bar after the letter.
    if (p.active == 0) return;
    const shown_end = view.first + shown;
    const before = gb.TextOffsetToX(rp, text + view.first, shown, view.cursor - view.first);
    const cursor_x = left + before;
    const under = if (past_end or view.cursor >= shown_end) 0 else @min(clusterLength(text, view.len, view.cursor), shown_end - view.cursor);
    const cursor_w: i32 = if (past_end) space_w else gb.TextOffsetToX(rp, text + view.first, shown, view.cursor - view.first + under) - before;
    d.box(gb, rp, cursor_x, top, @max(cursor_w, 1), @intCast(height), ink);
    if (under > 0 and cursor_w > 0) {
        d.pen(gb, rp, paper);
        gb.Move(rp, cursor_x, top + @as(i32, @intCast(baseline)));
        gb.Text(rp, text + view.cursor, under);
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
    _ = copyText(buffer, undo, p.max_chars);
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
                    _ = copyText(into, from, p.max_chars);
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
                p.buffer_pos = startAt(p, @truncate(item.data));
                changed = true;
            },
            gc.STRINGA_DispPos => {
                p.disp_pos = startAt(p, @truncate(item.data));
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
            gc.STRINGA_Secret => p.secret = @intFromBool(item.data != 0),
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

/// The cursor moved to the character a press landed on: the one whose
/// cell the pointer is in, in the piece of the line that was last drawn,
/// from where it began then and in the font it was drawn in. A press
/// past the last character shown lands on it, or after it when it ends
/// the text.
fn cursorTo(ib: *IntuitionBase, p: *Data, gi: ?*classusr.GadgetInfo, x: i32) void {
    const it = ib.iface();
    const gb = ib.graphics_base;
    const text = textShown(ib, p) orelse return;
    const port = it.ObtainGIRPort(gi) orelse return;
    defer it.ReleaseGIRPort(port);
    if (p.font) |font| graphics.SetFont(gb, port, font);
    const view = shownView(p, text);
    const click = x - p.text_left;
    var at = view.first;
    if (click > 0 and view.len > view.first) {
        const rest = view.len - view.first;
        const drawn = if (p.disp_count > 0) @min(p.disp_count, rest) else rest;
        // The place nearest the pointer may be the one right of it: the
        // cursor is the cell the pointer is in, so its left edge.
        var landed = gb.TextXToOffset(port, text + view.first, drawn, click);
        while (landed > 0 and gb.TextOffsetToX(port, text + view.first, drawn, landed) > click) {
            landed = charBefore(text + view.first, landed);
        }
        at += landed;
        // Past the last character shown: on it, or after it when it ends
        // the text.
        const shown_end = view.first + p.disp_count;
        if (p.disp_count > 0 and at >= shown_end) {
            at = if (shown_end >= view.len) view.len else charBefore(text, shown_end);
        }
    }
    p.buffer_pos = bufferAt(p, @min(at, view.len));
}

/// The text drawn, with the cursor and the first byte shown in its
/// bytes.
fn shownView(p: *const Data, text: [*]const u8) Shown {
    if (p.secret == 0) return .{ .text = text, .len = p.num_chars, .cursor = p.buffer_pos, .first = p.disp_pos };
    const buffer = p.buffer.?;
    return .{
        .text = text,
        .len = charCount(buffer, p.num_chars),
        .cursor = charCount(buffer, p.buffer_pos),
        .first = charCount(buffer, @min(p.disp_pos, p.num_chars)),
    };
}

/// A byte of the text drawn as the byte of the buffer it stands for:
/// itself, or while the field is secret the start of the character its
/// asterisk stands for.
fn bufferAt(p: *const Data, shown: u32) u32 {
    if (p.secret == 0) return shown;
    return charStart(p.buffer.?, p.num_chars, shown);
}

/// A position a program gave, as far as the text goes and moved back to
/// where the character it falls in starts.
fn startAt(p: *const Data, at: u32) u32 {
    const buffer = p.buffer orelse return 0;
    const within = @min(at, p.num_chars);
    return @intCast(utf8.cut(buffer[0..p.num_chars], within));
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
    if (p.mask) |m| ib.sys_base.FreeVec(m);
    p.buffer = null;
    p.undo = null;
    p.work = null;
    p.mask = null;
}

/// What is drawn and measured in the text's place: the buffer itself, or
/// a `mask_char` for each of its characters while the field is secret -
/// so that where the text scrolls to and what a press lands on are
/// measured on what is shown, not on what is hidden. Null when the field
/// is secret and there is no room for the mask, and then nothing of the
/// text is drawn: an empty field is the one safe thing to show.
fn textShown(ib: *IntuitionBase, p: *Data) ?[*]const u8 {
    const buffer = p.buffer orelse return null;
    if (p.secret == 0) return buffer;
    if (p.mask == null) {
        const memory = ib.sys_base.AllocVec(p.max_chars + 1, sdk.exec.MEMF_ANY) orelse return null;
        p.mask = @ptrCast(memory);
    }
    const mask = p.mask.?;
    const count = @min(charCount(buffer, p.num_chars), p.max_chars);
    @memset(mask[0..count], mask_char);
    mask[count] = 0;
    return mask;
}

/// A key edited: the global hook and then the gadget's own on the work,
/// and what they asked for done. A key that made several characters has
/// the hooks see each of them in turn, as a key of its own on the same
/// work, until one of them ends the gadget or throws the work away; and
/// when one of the characters is refused - no room, not a digit - none
/// of them goes in, so that no syllable is left cut.
fn editKey(ib: *IntuitionBase, cl: *Class, o: *Object, p: *Data, in: *gc.GpInput, e: *const ie.InputEvent) usize {
    var text: [key_room]u8 = undefined;
    var code: u32 = 0;
    var rest: []const u8 = &.{};
    if (ib.keymap_base) |kb| {
        const count = kb.MapRawKey(e, &text, text.len, p.key_map);
        if (km.character(&text, count)) |char| {
            code = char;
        } else if (km.typed(&text, count)) |string| {
            const first = utf8.read(string);
            code = first.char;
            rest = string[first.length..];
        }
    }
    const several = rest.len != 0;
    var w = startWork(o, p, e, code, in.gadget_info) orelse return gc.GMR_MEACTIVE;
    var command: u32 = sg.SGH_KEY;
    const ub = ib.utility_base;
    while (true) {
        _ = ub.CallHookPkt(ib.edit_hook, &w, &command);
        if (p.edit_hook) |hook| _ = ub.CallHookPkt(hook, &w, &command);
        if (rest.len == 0 or w.actions & sg.SGA_END != 0 or w.actions & sg.SGA_USE == 0) break;
        const next = utf8.read(rest);
        w.code = next.char;
        rest = rest[next.length..];
    }
    if (several and w.actions & sg.SGA_BEEP != 0) w.actions &= ~@as(u32, sg.SGA_USE);

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
                gc.STRINGA_Secret => get.storage.* = @intFromBool(p.secret != 0),
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
        gc.GM_DOMAIN => {
            const ask: *gc.GpDomain = @ptrCast(@alignCast(msg));
            ask.domain = domain(ib, cl, o.?, ask.gadget_info, ask.which);
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
        // The key that works a line of text gives it the keyboard: what
        // the key does after that is typing, not a shortcut.
        gc.GM_KEY => {
            const k: *gc.GpKey = @ptrCast(@alignCast(msg));
            if (!gc.keyIsFor(o.?, k)) return gc.GMKR_NOTHING;
            return if (own(cl, o.?).buffer == null) gc.GMKR_NOTHING else gc.GMKR_ACTIVATE;
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
            // The menu button ends it without an answer, and the press
            // goes on to open the menus: a line of text with the keys
            // does not keep them from the window.
            if (e.class == ie.IECLASS_NEWPOINTERPOS and e.code == ie.IECODE_RBUTTON) {
                p.active = 0;
                redraw(ib, o.?, in.gadget_info);
                tell(ib, cl, o.?, in.gadget_info, 0);
                return gc.GMR_REUSE;
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
