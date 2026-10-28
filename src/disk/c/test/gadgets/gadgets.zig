// SPDX-License-Identifier: MIT
//! Gadgets: the gadget classes on the disk, in a window. Built against the
//! SDK only.
//!
//!   Gadgets TOUCH/S
//!
//! It opens the gadget classes of `SYS:classes/gadgets/` - checkbox,
//! cycle, radiobutton, string, text, slider, palette and toolbutton - and
//! command.image from `SYS:classes/images/`, and a window object on the
//! default public screen holding one layout, each gadget labelled by it:
//! a row of tool buttons - "New" large with its command picture and
//! "Folder" large with the system's default drawer icon, "Cut", "Copy"
//! and a disabled "Paste" medium in a column, and "Wrap" a small toggle
//! whose label is its hint - then a line to type a name in, a number
//! field, a check box "Backups", a
//! second one "Locked" that is ticked and disabled, a cycle "Level" of Low,
//! Medium and High, a radio column "Port" of Serial, USB and None, a
//! slider "Volume" from 0 to 64 showing its level, a palette "Colour" of
//! eight colours, a text line "Last" in a
//! sunk frame, and an OK button. Every gadget let go is printed with its
//! ID, its name and the code it finished with - the check box's state, the
//! cycle's choice, the radio button's line, the slider's level, the
//! colour's number, the key
//! that ended a line - and the text line shows the code, set in the
//! window with SetGadgetAttrsTagList. OK prints the name and the number;
//! OK, the close gadget or Ctrl-C end it.
//!
//! Every label has an `_` before the letter that works its gadget, and
//! that letter is underlined: `b` turns the check box over, `e` steps the
//! cycle gadget on and Shift-`e` back, `v` moves the slider, `o` presses
//! OK, `n` gives the name field the keyboard, `t` and `y` cut and copy,
//! `a` turns Wrap over. `Locked`
//! is disabled, so its `l` does nothing and the key reaches the program
//! instead. A tool button's code is 0, a toggle's its new state.
//!
//! With `TOUCH` the check boxes and the radio group fill the room the
//! layout gives them instead of being a line of text high, which is what
//! a finger on a touch screen needs.

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
const cy = sdk.gadgets.cycle;
const rb = sdk.gadgets.radiobutton;
const st = sdk.gadgets.string;
const tx = sdk.gadgets.text;
const sl = sdk.gadgets.slider;
const pa = sdk.gadgets.palette;
const tb = sdk.gadgets.toolbutton;
const command = sdk.images.command;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Gadgets";
const VERSION_STRING = "\x00$VER: Gadgets 1.6 (28.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TOUCH/S";
const arg_touch = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Press the gadgets. OK, the close gadget or Ctrl-C end it\n";
const MSG_GADGET = "Gadget %lu (%s): code %ld\n";
const MSG_VALUES = "Name \"%s\", number %ld\n";

const ID_BACKUPS = 1;
const ID_LOCKED = 2;
const ID_LEVEL = 3;
const ID_PORT = 4;
const ID_OK = 5;
const ID_NAME = 6;
const ID_NUMBER = 7;
const ID_VOLUME = 8;
const ID_LAST = 9;
const ID_COLOUR = 10;
const ID_NEW = 11;
const ID_FOLDER = 12;
const ID_CUT = 13;
const ID_COPY = 14;
const ID_PASTE = 15;
const ID_WRAP = 16;

/// The palette's colours.
const colours = [_]sdk.graphics.Pen{
    0xFF000000, 0xFFFFFFFF, 0xFFCC3333, 0xFF33AA33,
    0xFF3366CC, 0xFFEECC33, 0xFFAA55CC, 0xFF33BBBB,
};

const levels = [_:null]?[*:0]const u8{ "Low", "Medium", "High" };
const ports = [_:null]?[*:0]const u8{ "Serial", "USB", "None" };

fn nameOf(id: usize) [*:0]const u8 {
    return switch (id) {
        ID_BACKUPS => "Backups",
        ID_LOCKED => "Locked",
        ID_LEVEL => "Level",
        ID_PORT => "Port",
        ID_OK => "OK",
        ID_NAME => "Name",
        ID_NUMBER => "Number",
        ID_VOLUME => "Volume",
        ID_COLOUR => "Colour",
        ID_NEW => "New",
        ID_FOLDER => "Folder",
        ID_CUT => "Cut",
        ID_COPY => "Copy",
        ID_PASTE => "Paste",
        ID_WRAP => "Wrap",
        else => "?",
    };
}

/// The gadgets the program reads or sets after they are made.
const Shown = struct {
    layout: *Object,
    name: *Object,
    number: *Object,
    last: *Object,
};

/// The command pictures the tool buttons show, in the order of `Pictures`.
const commands = [_]u32{ command.CMD_NEW, command.CMD_CUT, command.CMD_COPY, command.CMD_PASTE, command.CMD_WRAP };
const Pictures = struct { new: *Object, cut: *Object, copy: *Object, paste: *Object, wrap: *Object };

/// A tool button whose picture is a command image (`TOOLBUTTON_Image`)
/// or an icon of the system's defaults (`TOOLBUTTON_IconName`).
fn tool(ib: *IntuitionBase, id: u32, label: [*:0]const u8, picture: TagItem, size: u32, more: []const TagItem) ?*Object {
    var tags = [_]TagItem{
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(label) },
        picture,
        .{ .tag = tb.TOOLBUTTON_Size, .data = size },
        .{ .tag = sdk.utility.TAG_MORE, .data = @intFromPtr(more.ptr) },
    };
    if (more.len == 0) tags[4] = .{};
    return ib.NewObjectTagList(null, tb.TOOLBUTTON_CLASS, &tags);
}

fn image(picture: *Object) TagItem {
    return .{ .tag = tb.TOOLBUTTON_Image, .data = @intFromPtr(picture) };
}

/// The row of tool buttons: two large ones, a column of three medium ones
/// and a small toggle. Null, with whatever was made freed, when one of
/// them could not be made; the pictures stay the caller's.
fn toolRow(ib: *IntuitionBase, pictures: Pictures) ?*Object {
    const new = tool(ib, ID_NEW, "Ne_w", image(pictures.new), tb.TBSIZE_LARGE, &.{});
    const folder = tool(ib, ID_FOLDER, "_Folder", .{ .tag = tb.TOOLBUTTON_IconName, .data = @intFromPtr("ENV:Sys/def_drawer") }, tb.TBSIZE_LARGE, &.{});
    const cut = tool(ib, ID_CUT, "Cu_t", image(pictures.cut), tb.TBSIZE_MEDIUM, &.{});
    const copy = tool(ib, ID_COPY, "Cop_y", image(pictures.copy), tb.TBSIZE_MEDIUM, &.{});
    const paste = tool(ib, ID_PASTE, "Pa_ste", image(pictures.paste), tb.TBSIZE_MEDIUM, &.{
        .{ .tag = gc.GA_Disabled, .data = 1 },
        .{},
    });
    const wrap = tool(ib, ID_WRAP, "Wr_ap", image(pictures.wrap), tb.TBSIZE_SMALL, &.{
        .{ .tag = tb.TOOLBUTTON_Kind, .data = tb.TBKIND_TOGGLE },
        .{ .tag = tb.TOOLBUTTON_Hint, .data = @intFromPtr("Wrap the lines at the window's edge") },
        .{},
    });
    const parts = [_]?*Object{ new, folder, cut, copy, paste, wrap };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const column = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_VERT },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(cut) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(copy) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(paste) },
        .{},
    }) else null;
    const row = if (column) |c| ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 2 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(new) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(folder) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(c) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(wrap) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.CHILDA_Align, .data = lg.CALIGN_TOP },
        .{},
    }) else null;
    return row orelse {
        if (column) |c| {
            ib.DisposeObject(c);
            ib.DisposeObject(new);
            ib.DisposeObject(folder);
            ib.DisposeObject(wrap);
        } else for (parts) |part| ib.DisposeObject(part);
        return null;
    };
}

/// The layout and everything in it; null, with whatever was made freed,
/// when one of them could not be made.
fn build(ib: *IntuitionBase, touch: bool, pictures: Pictures) ?Shown {
    const tools = toolRow(ib, pictures);
    const name = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_NAME },
        .{ .tag = gc.STRINGA_MaxChars, .data = 40 },
        .{ .tag = gc.STRINGA_TextVal, .data = @intFromPtr("PowerOS") },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{},
    });
    const number = ib.NewObjectTagList(null, st.STRING_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_NUMBER },
        .{ .tag = gc.STRINGA_MaxChars, .data = 12 },
        .{ .tag = gc.STRINGA_LongVal, .data = 42 },
        .{ .tag = gc.STRINGA_Justification, .data = gc.GACT_STRINGRIGHT },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{},
    });
    const volume = ib.NewObjectTagList(null, sl.SLIDER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_VOLUME },
        .{ .tag = sl.SLIDER_Max, .data = 64 },
        .{ .tag = sl.SLIDER_Level, .data = 32 },
        .{ .tag = sl.SLIDER_LevelFormat, .data = @intFromPtr("%ld") },
        .{ .tag = sl.SLIDER_MaxLevelLen, .data = 2 },
        // Room for the level in pixels as well, for a proportional font
        // in which two characters say little about the width needed.
        .{ .tag = sl.SLIDER_MaxLevelPixels, .data = 28 },
        .{ .tag = sl.SLIDER_LevelJustify, .data = tx.TEXT_JUSTIFY_RIGHT },
        .{},
    });
    const colour = ib.NewObjectTagList(null, pa.PALETTE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_COLOUR },
        .{ .tag = pa.PALETTE_ColorTable, .data = @intFromPtr(&colours) },
        .{ .tag = pa.PALETTE_NumColors, .data = colours.len },
        .{ .tag = pa.PALETTE_Color, .data = 2 },
        .{},
    });
    const last = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LAST },
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("nothing yet") },
        .{ .tag = tx.TEXT_Border, .data = 1 },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{},
    });
    const backups = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_BACKUPS },
        .{ .tag = if (touch) cb.CHECKBOX_Scaled else sdk.utility.TAG_IGNORE, .data = 1 },
        .{},
    });
    const locked = ib.NewObjectTagList(null, cb.CHECKBOX_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LOCKED },
        .{ .tag = cb.CHECKBOX_Checked, .data = 1 },
        .{ .tag = gc.GA_Disabled, .data = 1 },
        .{ .tag = if (touch) cb.CHECKBOX_Scaled else sdk.utility.TAG_IGNORE, .data = 1 },
        .{},
    });
    const level = ib.NewObjectTagList(null, cy.CYCLE_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_LEVEL },
        .{ .tag = cy.CYCLE_Labels, .data = @intFromPtr(&levels) },
        .{ .tag = cy.CYCLE_Active, .data = 1 },
        .{},
    });
    const port = ib.NewObjectTagList(null, rb.RADIO_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_PORT },
        .{ .tag = rb.RADIO_Labels, .data = @intFromPtr(&ports) },
        .{ .tag = if (touch) rb.RADIO_Scaled else sdk.utility.TAG_IGNORE, .data = 1 },
        .{},
    });
    const ok = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_OK") },
        .{ .tag = gc.GA_ID, .data = ID_OK },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
    const parts = [_]?*Object{ tools, name, number, backups, locked, level, port, volume, colour, last, ok };
    var whole = true;
    for (parts) |part| whole = whole and part != null;
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(tools) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(name) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Name") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(number) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("N_umber") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(backups) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Backups") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(locked) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Locked") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(level) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("L_evel") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(port) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Port") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(volume) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Volume") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(colour) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Colour") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(last) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Last") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(ok) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;
    const whole_layout = layout orelse {
        for (parts) |part| ib.DisposeObject(part);
        return null;
    };
    return .{ .layout = whole_layout, .name = name.?, .number = number.?, .last = last.? };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const touch = argv[arg_touch] != 0;

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The class libraries, open for as long as their objects are there:
    // the window object is disposed of before they are closed.
    const wanted = [_][*:0]const u8{
        cb.CHECKBOX_LIBRARY, cy.CYCLE_LIBRARY,      rb.RADIO_LIBRARY,
        st.STRING_LIBRARY,   tx.TEXT_LIBRARY,       sl.SLIDER_LIBRARY,
        pa.PALETTE_LIBRARY,  tb.TOOLBUTTON_LIBRARY, command.COMMAND_LIBRARY,
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

    // The tool buttons' pictures, the program's: disposed of after the
    // window object and its buttons, before command.image is closed.
    var made: [commands.len]?*Object = @splat(null);
    defer for (made) |picture| ib.DisposeObject(picture);
    for (commands, 0..) |which, i| {
        made[i] = ib.NewObjectTagList(null, command.COMMAND_CLASS, &[_]TagItem{ .{ .tag = command.COMMAND_Glyph, .data = which }, .{} }) orelse {
            _ = Printf(dl, MSG_NOMEMORY, .{});
            return dos.RETURN_FAIL;
        };
    }
    const pictures = Pictures{ .new = made[0].?, .cut = made[1].?, .copy = made[2].?, .paste = made[3].?, .wrap = made[4].? };

    const shown = build(ib, touch, pictures) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    const layout = shown.layout;
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(layout, @ptrCast(&nominal));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Gadgets") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(nominal.domain.width + 40) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(nominal.domain.height) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(layout) },
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The window, the layout and every gadget in it, before the libraries
    // their classes are in.
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
                    _ = Printf(dl, MSG_GADGET, .{ @as(u64, id), nameOf(id), @as(i64, value) });
                    if (id == ID_OK) {
                        var text: usize = 0;
                        var number: usize = 0;
                        _ = ib.GetAttr(gc.STRINGA_TextVal, shown.name, &text);
                        _ = ib.GetAttr(gc.STRINGA_LongVal, shown.number, &number);
                        const typed: [*:0]const u8 = if (text != 0) @ptrFromInt(text) else "";
                        _ = Printf(dl, MSG_VALUES, .{ typed, @as(i64, @as(isize, @bitCast(number))) });
                        return dos.RETURN_OK;
                    }
                    // The text line shows the code, drawn at once.
                    _ = ib.SetGadgetAttrsTagList(shown.last, window, &[_]TagItem{
                        .{ .tag = tx.TEXT_Number, .data = @bitCast(@as(isize, value)) },
                        .{ .tag = tx.TEXT_Format, .data = @intFromPtr("code %ld") },
                        .{},
                    });
                },
                else => {},
            }
        }
    }
}
