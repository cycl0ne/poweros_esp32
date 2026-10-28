// SPDX-License-Identifier: MIT
//! Ribbon: ribbon.gadget in a window, its tool buttons showing
//! command.image's pictures. Built against the SDK only.
//!
//!   Ribbon
//!
//! It opens toolbutton.gadget, checkbox.gadget, text.gadget and
//! ribbon.gadget from `SYS:classes/gadgets/` and command.image from
//! `SYS:classes/images/`, and a window object on the default public screen
//! holding a ribbon of three tabs and a contextual one over a text line
//! that names the last command. The ribbon is made from a table with the
//! SDK's `ribbon.build`, which makes its buttons and their pictures too:
//!
//! - Home: Clipboard - Paste, a large split button whose list has two more
//!   ways to paste, disabled until something is cut or copied - the
//!   button found by its ID - and Cut and Copy medium; Font - Bold, Italic
//!   and Underline, small toggles, and a launcher; Paragraph - left,
//!   centred and right, small, Wrap a medium toggle, Spacing a drop-down,
//!   and a launcher.
//! - Insert: Data - Sum large and Sort medium; Table - Table tools, a
//!   large toggle that shows the contextual tab while it is on.
//! - View: Zoom - in and out, large; Find, large; Show - a check box
//!   "Grid" in a layout of its own, which a ribbon holds as it holds any
//!   gadget, and Settings, medium.
//! - Table, contextual: Rows - inserting and deleting one; Columns - the
//!   same, medium.
//!
//! Every command let go is printed with its ID, its name and its code - a
//! toggle's and the check box's new state, the label taken from a list,
//! -1 for a split button's own command - and the text line names it,
//! with the label taken from a list after the name. A
//! tab taken by a press, its key or the wheel over the row is printed
//! with its number. `h`, `n`, `v` and, while it is there, `a` turn to the
//! tabs; the other keys underlined work only on the tab in front.
//!
//! Made narrower, the window shows the groups smaller, the rightmost
//! first: large buttons medium, then every button small, then a group
//! folded into a button with its picture, which drops the group down. The
//! mark at the row's right end, or a double-click on a tab, minimizes the
//! ribbon to its row - a tab then drops its page down - and the window is
//! laid out again for it (`WM_RETHINK`). The close gadget or Ctrl-C end
//! it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const cb = sdk.gadgets.checkbox;
const tx = sdk.gadgets.text;
const tb = sdk.gadgets.toolbutton;
const rb = sdk.gadgets.ribbon;
const command = sdk.images.command;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Ribbon";
const VERSION_STRING = "\x00$VER: Ribbon 1.2 (28.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Press the commands and the tabs. The close gadget or Ctrl-C end it\n";
const MSG_GADGET = "Command %lu (%s): code %ld\n";
const MSG_TAB = "Tab %ld\n";
const MSG_MINIMIZED = "Minimized\n";
const MSG_BACK = "Back again\n";

const ID_RIBBON = 1;
const ID_LAST = 2;

const ID_PASTE = 10;
const ID_CUT = 11;
const ID_COPY = 12;
const ID_GRID = 100;
/// The toggle that shows the contextual tab, and the tab's `id`.
const ID_TABLE_TOOLS = 45;
const TAB_TABLE = 7;

const pastes = [_:null]?[*:0]const u8{ "Paste as text", "Paste special" };
const spacings = [_:null]?[*:0]const u8{ "Single", "One and a half", "Double" };

/// The ribbon's table, with the check box `grid` - in a layout of its
/// own, which gives it its label - among its lines. A group's `id` is its
/// launcher's, which opens the group's settings.
fn tableWith(grid: ?*Object) [38]rb.NewRibbon {
    return .{
        .{ .type = rb.RB_TAB, .label = "_Home" },
        .{ .type = rb.RB_GROUP, .label = "Clipboard", .glyph = command.CMD_PASTE },
        .{ .type = rb.RB_LARGE, .id = ID_PASTE, .label = "_Paste", .glyph = command.CMD_PASTE, .kind = tb.TBKIND_SPLIT, .labels = &pastes, .flags = rb.RBF_DISABLED },
        .{ .type = rb.RB_MEDIUM, .id = ID_CUT, .label = "Cu_t", .glyph = command.CMD_CUT },
        .{ .type = rb.RB_MEDIUM, .id = ID_COPY, .label = "_Copy", .glyph = command.CMD_COPY },
        .{ .type = rb.RB_GROUP, .label = "Font", .glyph = command.CMD_BOLD, .id = 90 },
        .{ .type = rb.RB_SMALL, .id = 20, .label = "_Bold", .glyph = command.CMD_BOLD, .kind = tb.TBKIND_TOGGLE },
        .{ .type = rb.RB_SMALL, .id = 21, .label = "_Italic", .glyph = command.CMD_ITALIC, .kind = tb.TBKIND_TOGGLE },
        .{ .type = rb.RB_SMALL, .id = 22, .label = "_Underline", .glyph = command.CMD_UNDERLINE, .kind = tb.TBKIND_TOGGLE },
        .{ .type = rb.RB_GROUP, .label = "Paragraph", .glyph = command.CMD_ALIGN_LEFT, .id = 91 },
        .{ .type = rb.RB_SMALL, .id = 30, .label = "_Left", .glyph = command.CMD_ALIGN_LEFT },
        .{ .type = rb.RB_SMALL, .id = 31, .label = "C_entre", .glyph = command.CMD_ALIGN_CENTRE },
        .{ .type = rb.RB_SMALL, .id = 32, .label = "_Right", .glyph = command.CMD_ALIGN_RIGHT },
        .{ .type = rb.RB_MEDIUM, .id = 33, .label = "_Wrap", .glyph = command.CMD_WRAP, .kind = tb.TBKIND_TOGGLE },
        .{ .type = rb.RB_MEDIUM, .id = 34, .label = "_Spacing", .kind = tb.TBKIND_DROPDOWN, .labels = &spacings },

        .{ .type = rb.RB_TAB, .label = "I_nsert" },
        .{ .type = rb.RB_GROUP, .label = "Data", .glyph = command.CMD_SUM },
        .{ .type = rb.RB_LARGE, .id = 50, .label = "_Sum", .glyph = command.CMD_SUM },
        .{ .type = rb.RB_MEDIUM, .id = 51, .label = "S_ort", .glyph = command.CMD_SORT },
        .{ .type = rb.RB_GROUP, .label = "Table", .glyph = command.CMD_INSERT_COLUMN },
        .{ .type = rb.RB_LARGE, .id = ID_TABLE_TOOLS, .label = "_Table tools", .glyph = command.CMD_INSERT_COLUMN, .kind = tb.TBKIND_TOGGLE },

        .{ .type = rb.RB_TAB, .label = "_View" },
        .{ .type = rb.RB_GROUP, .label = "Zoom", .glyph = command.CMD_ZOOM_IN },
        .{ .type = rb.RB_LARGE, .id = 60, .label = "Zoom _in", .glyph = command.CMD_ZOOM_IN },
        .{ .type = rb.RB_LARGE, .id = 61, .label = "Zoom _out", .glyph = command.CMD_ZOOM_OUT },
        .{ .type = rb.RB_GROUP, .label = "Find", .glyph = command.CMD_FIND },
        .{ .type = rb.RB_LARGE, .id = 70, .label = "_Find", .glyph = command.CMD_FIND },
        .{ .type = rb.RB_GROUP, .label = "Show", .glyph = command.CMD_SETTINGS },
        .{ .type = rb.RB_GADGET, .id = ID_GRID, .label = "_Grid", .gadget = grid },
        .{ .type = rb.RB_MEDIUM, .id = 80, .label = "S_ettings", .glyph = command.CMD_SETTINGS },

        .{ .type = rb.RB_TAB, .label = "T_able", .id = TAB_TABLE, .flags = rb.RBF_CONTEXTUAL },
        .{ .type = rb.RB_GROUP, .label = "Rows", .glyph = command.CMD_INSERT_ROW },
        .{ .type = rb.RB_MEDIUM, .id = 40, .label = "Insert _row", .glyph = command.CMD_INSERT_ROW },
        .{ .type = rb.RB_MEDIUM, .id = 41, .label = "_Delete row", .glyph = command.CMD_DELETE_ROW },
        .{ .type = rb.RB_GROUP, .label = "Columns", .glyph = command.CMD_INSERT_COLUMN },
        .{ .type = rb.RB_MEDIUM, .id = 42, .label = "Insert co_lumn", .glyph = command.CMD_INSERT_COLUMN },
        .{ .type = rb.RB_MEDIUM, .id = 43, .label = "Delete colu_mn", .glyph = command.CMD_DELETE_COLUMN },
        .{ .type = rb.RB_END },
    };
}

/// The name of the command `id` as it is shown, in `buffer`: its line's
/// label without the `_`, and the label taken from its list after it -
/// or, for a launcher, its group's name and what it opens.
fn nameOf(table: []const rb.NewRibbon, id: usize, value: i32, buffer: *[48:0]u8) [*:0]const u8 {
    for (table) |line| {
        if (line.type == rb.RB_GROUP and line.id != 0 and line.id == id) {
            var n = put(buffer, 0, line.label.?);
            n = put(buffer, n, " settings");
            buffer[n] = 0;
            return buffer;
        }
    }
    for (table) |line| {
        if (line.type == rb.RB_TAB or line.type == rb.RB_GROUP or line.id != id) continue;
        var n = put(buffer, 0, line.label orelse "?");
        if (line.labels) |list| if (value >= 0) {
            const taken: usize = @intCast(value);
            var i: usize = 0;
            while (list[i]) |label| : (i += 1) {
                if (i != taken) continue;
                n = put(buffer, n, ": ");
                n = put(buffer, n, label);
                break;
            }
        };
        buffer[n] = 0;
        return buffer;
    }
    return "?";
}

/// `text` put in `buffer` from `n` on without its `_`, as far as there is
/// room; where it ends.
fn put(buffer: *[48:0]u8, n: usize, text: [*:0]const u8) usize {
    var at = n;
    var i: usize = 0;
    while (text[i] != 0 and at < buffer.len) : (i += 1) {
        if (text[i] == '_') continue;
        buffer[at] = text[i];
        at += 1;
    }
    return at;
}

/// The check box "Grid", in a layout that gives it its label; null
/// without the memory.
fn gridBox(ib: *IntuitionBase, label: [*:0]const u8) ?*Object {
    const box = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_GRID },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    }) orelse return null;
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(box) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(label) },
        .{},
    }) orelse {
        ib.DisposeObject(box);
        return null;
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The class libraries, open for as long as their objects are there:
    // the window object and the pictures are disposed of before they are
    // closed.
    const wanted = [_][*:0]const u8{
        tb.TOOLBUTTON_LIBRARY, cb.CHECKBOX_LIBRARY,     tx.TEXT_LIBRARY,
        rb.RIBBON_LIBRARY,     command.COMMAND_LIBRARY,
    };
    var libraries: [wanted.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (wanted, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    // The ribbon, its buttons and their pictures made from the table; the
    // pictures and the table's block go last, after the window object has
    // disposed of the ribbon. The check box is the ribbon's, made or not.
    const table = tableWith(gridBox(ib, "_Grid"));
    const built = rb.build(sys, ib, &table, &[_]TagItem{ .{ .tag = gc.GA_ID, .data = ID_RIBBON }, .{} }) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    defer built.free(sys, ib);
    const ribbon = built.ribbon;
    const last = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LAST },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("nothing yet") },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{},
    });
    const layout = if (last != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{ .tag = lg.LAYOUTA_Margin, .data = 4 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ribbon) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(last) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Last") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const whole = layout orelse {
        ib.DisposeObject(ribbon);
        ib.DisposeObject(last);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };

    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(whole, @ptrCast(&nominal));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Ribbon") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(nominal.domain.width) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(nominal.domain.height) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(whole) },
        .{},
    }) orelse {
        ib.DisposeObject(whole);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The window, the layout, the ribbon and every gadget in it, before
    // the pictures and the libraries.
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    if (ib.SendMessage(object, @ptrCast(&open)) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    var window_ptr: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, object, &window_ptr);
    const window: *intuition.Window = @ptrFromInt(window_ptr);
    _ = Printf(dl, MSG_HELLO, .{});

    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    // The last command's name, which the line under the ribbon shows.
    var shown: [48:0]u8 = undefined;
    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        while (true) {
            const word = ib.SendMessage(object, @ptrCast(&handle));
            if (word == wc.WMHI_LASTMSG) break;
            switch (word & wc.WMHI_CLASSMASK) {
                wc.WMHI_CLOSEWINDOW => return dos.RETURN_OK,
                wc.WMHI_GADGETUP => {
                    const id = word & wc.WMHI_GADGETMASK;
                    const value: i32 = @bitCast(code);
                    if (id == ID_RIBBON) {
                        if (value != rb.RBCODE_MINIMIZED) {
                            _ = Printf(dl, MSG_TAB, .{@as(i64, value)});
                            continue;
                        }
                        // Its height has changed: the window laid out
                        // again round it.
                        var minimized: usize = 0;
                        _ = ib.GetAttr(rb.RIBBON_Minimized, ribbon, &minimized);
                        _ = if (minimized != 0) Printf(dl, MSG_MINIMIZED, .{}) else Printf(dl, MSG_BACK, .{});
                        var rethink = wc.WmRethink{};
                        _ = ib.SendMessage(object, @ptrCast(&rethink));
                        continue;
                    }
                    // The contextual tab comes with its toggle and goes
                    // with it.
                    if (id == ID_TABLE_TOOLS) {
                        _ = ib.SetGadgetAttrsTagList(ribbon, window, &[_]TagItem{
                            .{ .tag = if (value != 0) rb.RIBBON_ShowTab else rb.RIBBON_HideTab, .data = TAB_TABLE },
                            .{},
                        });
                    }
                    // Something cut or copied, there is something to
                    // paste: the button found by its ID.
                    if (id == ID_CUT or id == ID_COPY) {
                        _ = ib.SetGadgetAttrsTagList(built.entry(ID_PASTE).?, window, &[_]TagItem{
                            .{ .tag = gc.GA_Disabled, .data = 0 },
                            .{},
                        });
                    }
                    const name = nameOf(&table, id, value, &shown);
                    _ = Printf(dl, MSG_GADGET, .{ @as(u64, id), name, @as(i64, value) });
                    _ = ib.SetGadgetAttrsTagList(last.?, window, &[_]TagItem{
                        .{ .tag = tx.TEXT_Text, .data = @intFromPtr(name) },
                        .{},
                    });
                },
                else => {},
            }
        }
    }
}
