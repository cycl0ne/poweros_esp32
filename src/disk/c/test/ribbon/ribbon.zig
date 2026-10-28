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
//! that names the last command:
//!
//! - Home: Clipboard - Paste, a large split button whose list has two more
//!   ways to paste, Cut and Copy medium; Font - Bold, Italic and Underline,
//!   small toggles, and a launcher; Paragraph - left, centred and right,
//!   small, Wrap a medium toggle, Spacing a drop-down, and a launcher.
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
const VERSION_STRING = "\x00$VER: Ribbon 1.1 (28.10.2026)\r\n";
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

/// What an entry of the ribbon is.
const Kind = enum { large, medium, small, toggle_large, toggle_medium, toggle_small, split_large, dropdown_medium, check };

/// An entry: its ID - the command - its picture, its label with the `_`
/// before its key, how it is made, and the list a split or a drop-down
/// button has.
const Entry = struct {
    id: u32,
    glyph: u32 = command.CMD_NONE,
    label: [*:0]const u8,
    kind: Kind,
    labels: ?[*:null]const ?[*:0]const u8 = null,
};
/// A group: its name, the picture of the button it is folded into, and
/// its launcher's ID and what that opens, when it has one.
const Group = struct {
    label: [*:0]const u8,
    glyph: u32 = command.CMD_NONE,
    launcher: u32 = 0,
    opens: [*:0]const u8 = "",
    entries: []const Entry,
};
const Tab = struct { label: [*:0]const u8, groups: []const Group, contextual: u32 = 0 };

const ID_GRID = 100;
/// The toggle that shows the contextual tab, and the tab's `id`.
const ID_TABLE_TOOLS = 45;
const TAB_TABLE = 7;

const pastes = [_:null]?[*:0]const u8{ "Paste as text", "Paste special" };
const spacings = [_:null]?[*:0]const u8{ "Single", "One and a half", "Double" };

const tabs = [_]Tab{
    .{ .label = "_Home", .groups = &.{
        .{ .label = "Clipboard", .glyph = command.CMD_PASTE, .entries = &.{
            .{ .id = 10, .glyph = command.CMD_PASTE, .label = "_Paste", .kind = .split_large, .labels = &pastes },
            .{ .id = 11, .glyph = command.CMD_CUT, .label = "Cu_t", .kind = .medium },
            .{ .id = 12, .glyph = command.CMD_COPY, .label = "_Copy", .kind = .medium },
        } },
        .{ .label = "Font", .glyph = command.CMD_BOLD, .launcher = 90, .opens = "Font settings", .entries = &.{
            .{ .id = 20, .glyph = command.CMD_BOLD, .label = "_Bold", .kind = .toggle_small },
            .{ .id = 21, .glyph = command.CMD_ITALIC, .label = "_Italic", .kind = .toggle_small },
            .{ .id = 22, .glyph = command.CMD_UNDERLINE, .label = "_Underline", .kind = .toggle_small },
        } },
        .{ .label = "Paragraph", .glyph = command.CMD_ALIGN_LEFT, .launcher = 91, .opens = "Paragraph settings", .entries = &.{
            .{ .id = 30, .glyph = command.CMD_ALIGN_LEFT, .label = "_Left", .kind = .small },
            .{ .id = 31, .glyph = command.CMD_ALIGN_CENTRE, .label = "C_entre", .kind = .small },
            .{ .id = 32, .glyph = command.CMD_ALIGN_RIGHT, .label = "_Right", .kind = .small },
            .{ .id = 33, .glyph = command.CMD_WRAP, .label = "_Wrap", .kind = .toggle_medium },
            .{ .id = 34, .label = "_Spacing", .kind = .dropdown_medium, .labels = &spacings },
        } },
    } },
    .{ .label = "I_nsert", .groups = &.{
        .{ .label = "Data", .glyph = command.CMD_SUM, .entries = &.{
            .{ .id = 50, .glyph = command.CMD_SUM, .label = "_Sum", .kind = .large },
            .{ .id = 51, .glyph = command.CMD_SORT, .label = "S_ort", .kind = .medium },
        } },
        .{ .label = "Table", .glyph = command.CMD_INSERT_COLUMN, .entries = &.{
            .{ .id = ID_TABLE_TOOLS, .glyph = command.CMD_INSERT_COLUMN, .label = "_Table tools", .kind = .toggle_large },
        } },
    } },
    .{ .label = "_View", .groups = &.{
        .{ .label = "Zoom", .glyph = command.CMD_ZOOM_IN, .entries = &.{
            .{ .id = 60, .glyph = command.CMD_ZOOM_IN, .label = "Zoom _in", .kind = .large },
            .{ .id = 61, .glyph = command.CMD_ZOOM_OUT, .label = "Zoom _out", .kind = .large },
        } },
        .{ .label = "Find", .glyph = command.CMD_FIND, .entries = &.{
            .{ .id = 70, .glyph = command.CMD_FIND, .label = "_Find", .kind = .large },
        } },
        .{ .label = "Show", .glyph = command.CMD_SETTINGS, .entries = &.{
            .{ .id = ID_GRID, .label = "_Grid", .kind = .check },
            .{ .id = 80, .glyph = command.CMD_SETTINGS, .label = "S_ettings", .kind = .medium },
        } },
    } },
    .{ .label = "T_able", .contextual = TAB_TABLE, .groups = &.{
        .{ .label = "Rows", .glyph = command.CMD_INSERT_ROW, .entries = &.{
            .{ .id = 40, .glyph = command.CMD_INSERT_ROW, .label = "Insert _row", .kind = .medium },
            .{ .id = 41, .glyph = command.CMD_DELETE_ROW, .label = "_Delete row", .kind = .medium },
        } },
        .{ .label = "Columns", .glyph = command.CMD_INSERT_COLUMN, .entries = &.{
            .{ .id = 42, .glyph = command.CMD_INSERT_COLUMN, .label = "Insert co_lumn", .kind = .medium },
            .{ .id = 43, .glyph = command.CMD_DELETE_COLUMN, .label = "Delete colu_mn", .kind = .medium },
        } },
    } },
};

const max_groups = 3;
const max_entries = 5;

/// The name of the entry `id` as it is shown: its label without the `_`,
/// in `buffer` - or what a launcher opens.
fn nameOf(id: usize, value: i32, buffer: *[48:0]u8) [*:0]const u8 {
    for (tabs) |tab| for (tab.groups) |group| {
        if (group.launcher != 0 and group.launcher == id) return group.opens;
    };
    for (tabs) |tab| for (tab.groups) |group| for (group.entries) |entry| {
        if (entry.id != id) continue;
        var n: usize = 0;
        n = put(buffer, n, entry.label);
        // The label taken from its list after it.
        if (entry.labels) |list| if (value >= 0) {
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
    };
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

/// What the program makes for the ribbon: the gadgets, in the lists the
/// ribbon reads (`RibbonTab`, `RibbonGroup`), and the pictures the tool
/// buttons show, which stay the program's. Kept for as long as the ribbon
/// is there.
const Made = struct {
    entries: [tabs.len][max_groups][max_entries + 1]?*Object = @splat(@splat(@splat(null))),
    pictures: [tabs.len][max_groups][max_entries]?*Object = @splat(@splat(@splat(null))),
    /// The pictures of the buttons the groups are folded into.
    folded: [tabs.len][max_groups]?*Object = @splat(@splat(null)),
    groups: [tabs.len][max_groups + 1]rb.RibbonGroup = @splat(@splat(.{})),
    tabs: [tabs.len + 1]rb.RibbonTab = @splat(.{}),

    /// Every gadget and picture made; false, with what was made left for
    /// `free`, when one could not be.
    fn make(m: *Made, ib: *IntuitionBase) bool {
        for (tabs, 0..) |tab, t| {
            for (tab.groups, 0..) |group, g| {
                for (group.entries, 0..) |entry, e| {
                    if (entry.glyph != command.CMD_NONE) {
                        m.pictures[t][g][e] = ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{
                            .{ .tag = command.COMMAND_Glyph, .data = entry.glyph },
                            .{},
                        }) orelse return false;
                    }
                    m.entries[t][g][e] = gadget(ib, entry, m.pictures[t][g][e]) orelse return false;
                }
                if (group.glyph != command.CMD_NONE) {
                    m.folded[t][g] = ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{
                        .{ .tag = command.COMMAND_Glyph, .data = group.glyph },
                        .{},
                    }) orelse return false;
                }
                m.groups[t][g] = .{
                    .label = group.label,
                    .items = &m.entries[t][g],
                    .launcher = group.launcher,
                    .image = m.folded[t][g],
                };
            }
            m.tabs[t] = .{
                .label = tab.label,
                .groups = &m.groups[t],
                .id = tab.contextual,
                .contextual = @intFromBool(tab.contextual != 0),
            };
        }
        return true;
    }

    /// The gadgets, when no ribbon has them.
    fn freeEntries(m: *Made, ib: *IntuitionBase) void {
        for (&m.entries) |*tab| for (tab) |*group| for (group) |*entry| {
            ib.DisposeObject(entry.*);
            entry.* = null;
        };
    }

    /// The pictures, after the gadgets showing them.
    fn freePictures(m: *Made, ib: *IntuitionBase) void {
        for (&m.pictures) |*tab| for (tab) |*group| for (group) |*picture| {
            ib.DisposeObject(picture.*);
            picture.* = null;
        };
        for (&m.folded) |*tab| for (tab) |*picture| {
            ib.DisposeObject(picture.*);
            picture.* = null;
        };
    }
};

/// An entry made: a tool button with its picture, or the check box in a
/// layout that gives it its label.
fn gadget(ib: *IntuitionBase, entry: Entry, picture: ?*Object) ?*Object {
    if (entry.kind == .check) {
        const box = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
            .{ .tag = gc.GA_ID, .data = entry.id },
            .{ .tag = gc.GA_RelVerify, .data = 1 },
            .{},
        }) orelse return null;
        return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
            .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(box) },
            .{ .tag = lg.CHILDA_Label, .data = @intFromPtr(entry.label) },
            .{},
        }) orelse {
            ib.DisposeObject(box);
            return null;
        };
    }
    const size: u32 = switch (entry.kind) {
        .large, .toggle_large, .split_large => tb.TBSIZE_LARGE,
        .small, .toggle_small => tb.TBSIZE_SMALL,
        else => tb.TBSIZE_MEDIUM,
    };
    const kind: u32 = switch (entry.kind) {
        .toggle_large, .toggle_medium, .toggle_small => tb.TBKIND_TOGGLE,
        .split_large => tb.TBKIND_SPLIT,
        .dropdown_medium => tb.TBKIND_DROPDOWN,
        else => tb.TBKIND_PUSH,
    };
    return ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = entry.id },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(entry.label) },
        .{ .tag = tb.TOOLBUTTON_Image, .data = @intFromPtr(picture) },
        .{ .tag = tb.TOOLBUTTON_Size, .data = size },
        .{ .tag = tb.TOOLBUTTON_Kind, .data = kind },
        .{ .tag = if (entry.labels != null) tb.TOOLBUTTON_Labels else sdk.utility.TAG_IGNORE, .data = @intFromPtr(entry.labels) },
        .{},
    });
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

    // The pictures go last, after the buttons that show them.
    var made = Made{};
    defer made.freePictures(ib);
    if (!made.make(ib)) {
        made.freeEntries(ib);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    // From here the entries are the ribbon's, made or not.
    const ribbon = ib.NewObjectTagList(null, rb.RIBBON_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_RIBBON },
        .{ .tag = rb.RIBBON_Tabs, .data = @intFromPtr(&made.tabs) },
        .{},
    });
    const last = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LAST },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("nothing yet") },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{},
    });
    const layout = if (ribbon != null and last != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
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
                        _ = ib.GetAttr(rb.RIBBON_Minimized, ribbon.?, &minimized);
                        _ = if (minimized != 0) Printf(dl, MSG_MINIMIZED, .{}) else Printf(dl, MSG_BACK, .{});
                        var rethink = wc.WmRethink{};
                        _ = ib.SendMessage(object, @ptrCast(&rethink));
                        continue;
                    }
                    // The contextual tab comes with its toggle and goes
                    // with it.
                    if (id == ID_TABLE_TOOLS) {
                        _ = ib.SetGadgetAttrsTagList(ribbon.?, window, &[_]TagItem{
                            .{ .tag = if (value != 0) rb.RIBBON_ShowTab else rb.RIBBON_HideTab, .data = TAB_TABLE },
                            .{},
                        });
                    }
                    const name = nameOf(id, value, &shown);
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
