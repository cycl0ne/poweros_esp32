// SPDX-License-Identifier: MIT
//! textedit.gadget: text of many lines, to read and to edit - the inside
//! of a notepad.
//!
//! The text is Latin-1, its lines ended by line feeds, in a sunk field
//! with a scroller at the right; without `TEXTEDIT_WordWrap` a line wider
//! than the field scrolls sideways under a scroller along the bottom, and
//! with it a line goes on in the next row, broken after a space where it
//! has one. It is drawn in its window's font; a tab goes to the next
//! multiple of eight spaces.
//!
//! **Scrollers in the window's border** instead of its own: made with
//! `TEXTEDIT_Scrollers` false, the gadget is the field alone, and tells
//! where its view is as a datatype does - `TEXTEDIT_TopVert`,
//! `TEXTEDIT_TotalVert` and `TEXTEDIT_VisibleVert` in rows,
//! `TEXTEDIT_TopHoriz` and the others in pixels - each time one of them
//! changes. A scroller in the border whose `ICA_TARGET` is the gadget and
//! whose `ICA_MAP` turns `SCROLLER_Top` into `TEXTEDIT_TopVert` (or
//! `TEXTEDIT_TopHoriz`) moves the view as it is dragged; the program sets
//! the scroller's total, visible and top from what the gadget tells.
//!
//! **Typing.** A press puts the cursor where it lands and gives the gadget
//! the keyboard, until a press somewhere else. Characters go in at the
//! cursor in place of what is selected; the cursor keys, Home and End,
//! Page Up and Page Down move it - with Control, by a word and to the
//! text's ends - and with Shift they select as they go. Backspace and Del
//! take a character out, or what is selected; Return starts a line and
//! Tab puts in a tab. A drag selects, scrolling the text when it goes past
//! an edge; Shift with a press selects to there; a double press selects a
//! word. On a board with no keyboard the on-screen one comes up while it
//! is typed into.
//!
//! Control-A selects everything, Control-Z takes the last change back and
//! Control-Y puts it back again: undo goes back as far as memory allows,
//! a run of typing as one step. The keys a program answers - the right
//! Amiga key with anything, which is how a menu's shortcut is typed,
//! Control-C, -X and -V for the clipboard, and the menu button - end the
//! typing and go to the window as they would without it (`IDCMP_RAWKEY`,
//! `IDCMP_VANILLAKEY`, the menus), and the program gives the gadget the
//! keyboard back with `ActivateGadget` when it has done what they asked.
//!
//! **The clipboard** is the program's to work: the gadget only gives out
//! what is selected and takes text in its place (`TEM_SELECTION`,
//! `TEM_INSERT`). `copy`, `cut` and `paste` below do the rest from the
//! program's own process, through iffparse.library on the primary
//! clipboard unit as `FORM FTXT`, so that nothing intuition holds waits
//! for the clipboard.
//!
//! **Find and replace** are methods: `TEM_FIND` selects the next match and
//! brings it into view, `TEM_REPLACE` replaces a selected match and finds
//! the next, `TEM_REPLACEALL` replaces every one as a single step of undo.
//!
//!   const editor = ib.NewObjectTagList(null, te.TEXTEDIT_CLASS, &.{
//!       .{ .tag = gc.GA_ID, .data = 1 },
//!       .{ .tag = te.TEXTEDIT_Text, .data = @intFromPtr(bytes) },
//!       .{ .tag = te.TEXTEDIT_TextLength, .data = length },
//!       .{ .tag = te.TEXTEDIT_WordWrap, .data = 1 },
//!       .{},
//!   });
//!
//! The text is taken out again with `TEM_GETTEXT`, the length first:
//!
//!   const length = getAttr(te.TEXTEDIT_Length);
//!   var take = te.TepText{ .method_id = te.TEM_GETTEXT, .buffer = buffer, .size = length };
//!   _ = ib.DoGadgetMethodA(editor, window, null, @ptrCast(&take));
//!
//! It needs scroller.gadget as well, which it opens itself.

const exec = @import("../exec/exec.zig");
const utility = @import("../utility/utility.zig");
const classusr = @import("../intuition/classusr.zig");
const windows = @import("../intuition/windows.zig");
const iffparse = @import("../iffparse/iffparse.zig");
const clipboard = @import("../../devices/clipboard.zig");
const gadgets = @import("gadgets.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const IntuitionBase = @import("../../interface/intuition.zig").IntuitionBase;
const IFFParseBase = @import("../../interface/iffparse.zig").IFFParseBase;
const Object = classusr.Object;
const GadgetInfo = classusr.GadgetInfo;

/// What a program opens, and the class it then asks for.
pub const TEXTEDIT_LIBRARY = "gadgets/textedit.gadget";
pub const TEXTEDIT_CLASS = "textedit.gadget";

pub const TEXTEDIT_Dummy = gadgets.GADGETS_Dummy + 29 * gadgets.GADGETS_Step;
/// The text, copied: a pointer to its bytes, which need no NUL at the end,
/// with `TEXTEDIT_TextLength` in the same list. Made and set. Setting it
/// replaces the whole text, forgets what undo knew, puts the cursor at the
/// start and makes the text unchanged.
pub const TEXTEDIT_Text = TEXTEDIT_Dummy + 0x01;
/// How many bytes `TEXTEDIT_Text` is. Made and set, with it.
pub const TEXTEDIT_TextLength = TEXTEDIT_Dummy + 0x02;
/// How many bytes the text is now. Read only.
pub const TEXTEDIT_Length = TEXTEDIT_Dummy + 0x03;
/// Bool: lines wider than the field go on in the next row, rather than
/// scrolling sideways. Made, set and read.
pub const TEXTEDIT_WordWrap = TEXTEDIT_Dummy + 0x04;
/// Bool: the text can be read, selected and copied, and not changed.
/// Made, set and read.
pub const TEXTEDIT_ReadOnly = TEXTEDIT_Dummy + 0x05;
/// Bool: the text has been changed since it was set, or since this was
/// last set to false - which is what a program does when it has saved it.
/// Set and read; told to the target when it turns true.
pub const TEXTEDIT_Changed = TEXTEDIT_Dummy + 0x06;
/// The cursor's line and column, both from 0, the column counting bytes.
/// Read only; told to the target as the cursor moves.
pub const TEXTEDIT_CursorLine = TEXTEDIT_Dummy + 0x07;
pub const TEXTEDIT_CursorColumn = TEXTEDIT_Dummy + 0x08;
/// How many lines the text has. Read only.
pub const TEXTEDIT_Lines = TEXTEDIT_Dummy + 0x09;
/// Bool, made only: the gadget's own scrollers, at its right and along its
/// bottom. True unless said otherwise; false for a program that puts
/// scrollers in the window's border and joins them to the view.
pub const TEXTEDIT_Scrollers = TEXTEDIT_Dummy + 0x0A;
/// The view, in rows: the first one shown (made, set and read), how many
/// there are and how many show (read only). Told to the target when any
/// of them changes.
pub const TEXTEDIT_TopVert = TEXTEDIT_Dummy + 0x0B;
pub const TEXTEDIT_TotalVert = TEXTEDIT_Dummy + 0x0C;
pub const TEXTEDIT_VisibleVert = TEXTEDIT_Dummy + 0x0D;
/// The view across, in pixels: how far it is scrolled (set and read), the
/// widest row and the field's width (read only). Told as the rows are.
/// With `TEXTEDIT_WordWrap` nothing is wider than the field.
pub const TEXTEDIT_TopHoriz = TEXTEDIT_Dummy + 0x0E;
pub const TEXTEDIT_TotalHoriz = TEXTEDIT_Dummy + 0x0F;
pub const TEXTEDIT_VisibleHoriz = TEXTEDIT_Dummy + 0x10;

/// The class's own methods, sent with `DoGadgetMethodA` so that what they
/// change is drawn. Every one answers 0 when it did nothing.
pub const TEM_Dummy: classusr.MethodID = 0x800;
/// `TepText`: the whole text into `buffer`, as much as `size` holds.
/// Answers the text's length.
pub const TEM_GETTEXT: classusr.MethodID = 0x801;
/// `TepText`: what is selected into `buffer`, as much as `size` holds.
/// Answers how long the selection is - 0 for none, which is how a program
/// asks how much room it needs.
pub const TEM_SELECTION: classusr.MethodID = 0x802;
/// `TepInsert`: `text` in place of what is selected, or at the cursor, as
/// one step of undo; the cursor after it. Length 0 takes the selection
/// out. 0 when the text is read-only.
pub const TEM_INSERT: classusr.MethodID = 0x803;
/// `TepCommand` each: take the last change back, put it back again,
/// select everything.
pub const TEM_UNDO: classusr.MethodID = 0x804;
pub const TEM_REDO: classusr.MethodID = 0x805;
pub const TEM_SELECTALL: classusr.MethodID = 0x806;
/// `TepFind`: the next match of `text` after the cursor - before it with
/// `TEFF_BACKWARDS`, in any case with `TEFF_ANYCASE` - selected and
/// brought into view, going round from the end. 1 when there is one.
pub const TEM_FIND: classusr.MethodID = 0x807;
/// `TepFind`: what is selected, if it is a match of `text`, replaced with
/// `with`, and then the next match found as `TEM_FIND` does. 1 when one
/// was replaced.
pub const TEM_REPLACE: classusr.MethodID = 0x808;
/// `TepFind`: every match replaced with `with`, as one step of undo.
/// Answers how many.
pub const TEM_REPLACEALL: classusr.MethodID = 0x809;

/// `TepFind.flags`.
pub const TEFF_BACKWARDS: u32 = 1 << 0;
pub const TEFF_ANYCASE: u32 = 1 << 1;

/// TEM_UNDO, TEM_REDO, TEM_SELECTALL.
pub const TepCommand = extern struct {
    method_id: classusr.MethodID,
    gadget_info: ?*GadgetInfo = null,
};

/// TEM_GETTEXT, TEM_SELECTION.
pub const TepText = extern struct {
    method_id: classusr.MethodID,
    gadget_info: ?*GadgetInfo = null,
    buffer: ?[*]u8 = null,
    size: u32 = 0,
};

/// TEM_INSERT.
pub const TepInsert = extern struct {
    method_id: classusr.MethodID = TEM_INSERT,
    gadget_info: ?*GadgetInfo = null,
    text: ?[*]const u8 = null,
    length: u32 = 0,
};

/// TEM_FIND, TEM_REPLACE, TEM_REPLACEALL.
pub const TepFind = extern struct {
    method_id: classusr.MethodID,
    gadget_info: ?*GadgetInfo = null,
    text: [*]const u8,
    length: u32,
    with: ?[*]const u8 = null,
    with_length: u32 = 0,
    flags: u32 = 0,
};

const ID_FTXT = iffparse.MakeID("FTXT");
const ID_CHRS = iffparse.MakeID("CHRS");

/// What is selected in `editor`, written to the clipboard. Whether any
/// went. On the program's own process: the gadget is asked under
/// intuition's lock, and the clipboard is written after it.
pub fn copy(sys: *ExecBase, ib: *IntuitionBase, ip: *IFFParseBase, editor: *Object, window: *windows.Window) bool {
    const selected = takeSelection(sys, ib, editor, window) orelse return false;
    defer sys.FreeVec(selected.ptr);
    return writeClip(ip, selected);
}

/// What is selected written to the clipboard and taken out of the text, as
/// one step of undo. Whether it was.
pub fn cut(sys: *ExecBase, ib: *IntuitionBase, ip: *IFFParseBase, editor: *Object, window: *windows.Window) bool {
    const selected = takeSelection(sys, ib, editor, window) orelse return false;
    defer sys.FreeVec(selected.ptr);
    if (!writeClip(ip, selected)) return false;
    var out = TepInsert{};
    return ib.DoGadgetMethodA(editor, window, null, @ptrCast(&out)) != 0;
}

/// The clipboard's text put in place of what is selected, or at the
/// cursor. Whether there was text to put.
pub fn paste(sys: *ExecBase, ib: *IntuitionBase, ip: *IFFParseBase, editor: *Object, window: *windows.Window) bool {
    const text = readClip(sys, ip) orelse return false;
    defer sys.FreeVec(text.ptr);
    var in = TepInsert{ .text = text.ptr, .length = @intCast(text.len) };
    return ib.DoGadgetMethodA(editor, window, null, @ptrCast(&in)) != 0;
}

/// The selection, in memory of its own for the caller to FreeVec; null for
/// none.
fn takeSelection(sys: *ExecBase, ib: *IntuitionBase, editor: *Object, window: *windows.Window) ?[]u8 {
    var ask = TepText{ .method_id = TEM_SELECTION };
    const length: u32 = @truncate(ib.DoGadgetMethodA(editor, window, null, @ptrCast(&ask)));
    if (length == 0) return null;
    const memory: [*]u8 = @ptrCast(sys.AllocVec(length, exec.MEMF_ANY) orelse return null);
    var take = TepText{ .method_id = TEM_SELECTION, .buffer = memory, .size = length };
    const got: u32 = @truncate(ib.DoGadgetMethodA(editor, window, null, @ptrCast(&take)));
    return memory[0..@min(got, length)];
}

fn writeClip(ip: *IFFParseBase, text: []const u8) bool {
    if (text.len == 0) return false;
    const iff = ip.AllocIFF() orelse return false;
    defer ip.FreeIFF(iff);
    const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return false;
    defer ip.CloseClipboard(clip);
    iff.stream = @intFromPtr(clip);
    ip.InitIFFasClip(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_WRITE) != 0) return false;
    defer ip.CloseIFF(iff);
    if (ip.PushChunk(iff, ID_FTXT, iffparse.ID_FORM, iffparse.IFFSIZE_UNKNOWN) != 0) return false;
    if (ip.PushChunk(iff, 0, ID_CHRS, @intCast(text.len)) != 0) return false;
    if (ip.WriteChunkBytes(iff, text.ptr, @intCast(text.len)) < 0) return false;
    _ = ip.PopChunk(iff);
    _ = ip.PopChunk(iff);
    return true;
}

/// Every CHRS chunk of the clipboard's FTXT, one after another, in memory
/// of its own for the caller to FreeVec; null for no text.
fn readClip(sys: *ExecBase, ip: *IFFParseBase) ?[]u8 {
    const iff = ip.AllocIFF() orelse return null;
    defer ip.FreeIFF(iff);
    const clip = ip.OpenClipboard(clipboard.PRIMARY_CLIP) orelse return null;
    defer ip.CloseClipboard(clip);
    iff.stream = @intFromPtr(clip);
    ip.InitIFFasClip(iff);
    if (ip.OpenIFF(iff, iffparse.IFFF_READ) != 0) return null;
    defer ip.CloseIFF(iff);
    if (ip.StopChunk(iff, ID_FTXT, ID_CHRS) != 0) return null;
    var length: usize = 0;
    var gathered: ?[*]u8 = null;
    // A clip is read once, front to back, so the text grows as the chunks
    // come.
    while (ip.ParseIFF(iff, iffparse.IFFPARSE_SCAN) == 0) {
        const chunk = ip.CurrentChunk(iff) orelse continue;
        if (chunk.id != ID_CHRS or chunk.size <= 0) continue;
        const size: usize = @intCast(chunk.size);
        const bigger: [*]u8 = @ptrCast(sys.AllocVec(length + size, exec.MEMF_ANY) orelse break);
        if (gathered) |old| {
            @memcpy(bigger[0..length], old[0..length]);
            sys.FreeVec(old);
        }
        gathered = bigger;
        if (ip.ReadChunkBytes(iff, bigger + length, chunk.size) != chunk.size) break;
        length += size;
    }
    const text = gathered orelse return null;
    if (length == 0) {
        sys.FreeVec(text);
        return null;
    }
    return text[0..length];
}
