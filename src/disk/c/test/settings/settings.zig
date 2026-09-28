// SPDX-License-Identifier: MIT
//! Settings: the gadget classes a window of settings is made of, in a
//! window. Built against the SDK only.
//!
//!   Settings [PAGE/K/N]
//!
//! It opens clicktab.gadget, page.gadget, integer.gadget,
//! chooser.gadget, fuelgauge.gadget and text.gadget, and a window object
//! on the default public screen holding a row of tabs over a page gadget:
//!
//! - **General**: two groups in titled frames - "Startup", with a number
//!   field "Port" from 1 to 65535 and a chooser "Keymap" of eight
//!   keymaps - four of them shown at a time, so the panel scrolls - and
//!   "Sound", with a number field "Volume" from 0 to 64.
//! - **Copy**: a fuel gauge showing hundredths, and buttons that move it
//!   on and put it back.
//! - **About**: a line of text.
//!
//! The tabs are the page gadget's `ICA_TARGET`, and an `ICA_MAP` turns
//! `CLICKTAB_Current` into `PAGE_Current`, so pressing a tab turns the
//! page without the program hearing anything. `PAGE` opens it on a tab
//! other than the first. Every gadget let go is printed with its ID and
//! the code it finished with. The close gadget or Ctrl-C end it.
//!
//! Each label's underlined letter works its gadget: `t` takes the next
//! tab and Shift-`t` the one before, `p` gives the port field the
//! keyboard, `k` steps the keymap on and Shift-`k` back, `s` moves the
//! gauge on.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const icc = intuition.icclass;
const classusr = intuition.classusr;
const ct = sdk.gadgets.clicktab;
const pgc = sdk.gadgets.page;
const ig = sdk.gadgets.integer;
const ch = sdk.gadgets.chooser;
const fgg = sdk.gadgets.fuelgauge;
const tx = sdk.gadgets.text;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Settings";
const VERSION_STRING = "\x00$VER: Settings 1.0 (28.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "PAGE/K/N";
const arg_page = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Press the tabs and the gadgets. The close gadget or Ctrl-C end it\n";
const MSG_GADGET = "Gadget %lu (%s): code %ld\n";

const ID_TABS = 1;
const ID_PORT = 2;
const ID_KEYMAP = 3;
const ID_VOLUME = 4;
const ID_STEP = 5;
const ID_RESET = 6;

/// How much a press on Step moves the gauge on, in hundredths.
const step_by = 10;

fn nameOf(id: usize) [*:0]const u8 {
    return switch (id) {
        ID_TABS => "Tabs",
        ID_PORT => "Port",
        ID_KEYMAP => "Keymap",
        ID_VOLUME => "Volume",
        ID_STEP => "Step",
        ID_RESET => "Reset",
        else => "?",
    };
}

const tab_names = [_:null]?[*:0]const u8{ "General", "Copy", "About" };
const keymaps = [_:null]?[*:0]const u8{ "deutsch", "usa", "usa2", "france", "italia", "espana", "sverige", "norsk" };

/// What the tabs say and what the page shows, kept in step by the
/// connection alone: the tab's number becomes the page's.
const tab_to_page = [_]TagItem{
    .{ .tag = ct.CLICKTAB_Current, .data = pgc.PAGE_Current },
    // The gadget's own ID travels with every update and means nothing to
    // the page, so it is dropped here.
    .{ .tag = gc.GA_ID, .data = utility.TAG_IGNORE },
    .{},
};

/// The pages, which the page gadget is given a pointer to and keeps: it
/// does not copy them, so they live here rather than in `build`.
var pages: [tab_names.len:null]?*Object = @splat(null);

/// The gadgets the program reads or sets after they are made.
const Shown = struct {
    layout: *Object,
    tabs: *Object,
    gauge: *Object,
};

/// A layout in a frame with `title` in its top edge, holding `tags` -
/// at most twelve of them.
fn group(ib: *IntuitionBase, title: [*:0]const u8, tags: []const TagItem) ?*Object {
    var all: [16]TagItem = undefined;
    all[0] = .{ .tag = lg.LAYOUTA_FrameTitle, .data = @intFromPtr(title) };
    all[1] = .{ .tag = lg.LAYOUTA_Margin, .data = 6 };
    all[2] = .{ .tag = lg.LAYOUTA_Spacing, .data = 4 };
    for (tags, 3..) |item, i| all[i] = item;
    all[3 + tags.len] = .{};
    return ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &all);
}

/// The whole window's layout; null, with whatever was made freed, when
/// one of them could not be made.
fn build(ib: *IntuitionBase, first_tab: u32) ?Shown {
    const port = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_PORT },
        .{ .tag = ig.INTEGER_Min, .data = 1 },
        .{ .tag = ig.INTEGER_Max, .data = 65535 },
        .{ .tag = ig.INTEGER_Number, .data = 23 },
        .{},
    });
    const keymap = ib.NewObjectTagList(null, ch.CHOOSER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_KEYMAP },
        .{ .tag = ch.CHOOSER_Labels, .data = @intFromPtr(&keymaps) },
        .{ .tag = ch.CHOOSER_Active, .data = 0 },
        // Four of the eight at a time, so the panel is one that scrolls.
        .{ .tag = ch.CHOOSER_MaxPanelLines, .data = 4 },
        .{},
    });
    const volume = ib.NewObjectTagList(null, ig.INTEGER_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_VOLUME },
        .{ .tag = ig.INTEGER_Max, .data = 64 },
        .{ .tag = ig.INTEGER_Number, .data = 32 },
        .{ .tag = ig.INTEGER_Step, .data = 4 },
        .{},
    });
    const gauge = ib.NewObjectTagList(null, fgg.GAUGE_CLASS, &[_]TagItem{
        .{ .tag = fgg.GAUGE_Percent, .data = 1 },
        .{ .tag = fgg.GAUGE_Format, .data = @intFromPtr("%ld%%") },
        .{ .tag = fgg.GAUGE_Level, .data = 0 },
        .{},
    });
    const step = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Step") },
        .{ .tag = gc.GA_ID, .data = ID_STEP },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
    const reset = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr("_Reset") },
        .{ .tag = gc.GA_ID, .data = ID_RESET },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
    const about = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{
        .{ .tag = tx.TEXT_Text, .data = @intFromPtr("PowerOS settings, and the classes they are made of") },
        .{ .tag = tx.TEXT_Justification, .data = tx.TEXT_JUSTIFY_CENTER },
        .{ .tag = tx.TEXT_Clipped, .data = 1 },
        .{},
    });
    const parts = [_]?*Object{ port, keymap, volume, gauge, step, reset, about };
    for (parts) |part| if (part == null) {
        for (parts) |made| ib.DisposeObject(made);
        return null;
    };

    // Page one: two groups, each in a frame with its title in its edge.
    const startup = group(ib, "Startup", &[_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(port) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Port") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(keymap) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Keymap") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
    });
    const sound = group(ib, "Sound", &[_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(volume) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("_Volume") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
    });
    const general = if (startup != null and sound != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Spacing, .data = 6 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(startup) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(sound) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{},
    }) else null;

    // Page two: the gauge, and the buttons that move it.
    const buttons = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(step) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(reset) },
        .{},
    });
    const copy = if (buttons != null) group(ib, "How far along", &[_]TagItem{
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(gauge) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(buttons) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
    }) else null;

    const about_page = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 8 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(about) },
        .{},
    });

    const made_pages = [_]?*Object{ general, copy, about_page };
    for (made_pages) |made| if (made == null) {
        // What is not in a layout yet is this program's to free.
        if (general == null) {
            ib.DisposeObject(startup);
            ib.DisposeObject(sound);
        }
        if (copy == null) ib.DisposeObject(buttons);
        for ([_]?*Object{ general, copy, about_page }) |built| ib.DisposeObject(built);
        return null;
    };

    // The array of pages outlives the gadget: it is this program's, as
    // the tabs' names are.
    pages[0] = general;
    pages[1] = copy;
    pages[2] = about_page;
    const book = ib.NewObjectTagList(null, pgc.PAGE_CLASS, &[_]TagItem{
        .{ .tag = pgc.PAGE_Pages, .data = @intFromPtr(&pages) },
        .{ .tag = pgc.PAGE_Current, .data = first_tab },
        .{},
    });
    const tabs = if (book != null) ib.NewObjectTagList(null, ct.CLICKTAB_CLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = ID_TABS },
        .{ .tag = gc.GA_Key, .data = 't' },
        .{ .tag = ct.CLICKTAB_Labels, .data = @intFromPtr(&tab_names) },
        .{ .tag = ct.CLICKTAB_Current, .data = first_tab },
        .{ .tag = icc.ICA_TARGET, .data = @intFromPtr(book) },
        .{ .tag = icc.ICA_MAP, .data = @intFromPtr(&tab_to_page) },
        .{},
    }) else null;
    const layout = if (tabs != null) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = 6 },
        .{ .tag = lg.LAYOUTA_Spacing, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(tabs) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(book) },
        .{},
    }) else null;
    const whole = layout orelse {
        ib.DisposeObject(tabs);
        ib.DisposeObject(book); // and the pages in it
        if (book == null) for (made_pages) |built| ib.DisposeObject(built);
        return null;
    };
    return .{ .layout = whole, .tabs = tabs.?, .gauge = gauge.? };
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
    var first_tab: u32 = 0;
    if (argv[arg_page] != 0) {
        const given: *const i32 = @ptrFromInt(argv[arg_page]);
        if (given.* > 0 and given.* <= tab_names.len) first_tab = @intCast(given.* - 1);
    }

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The class libraries, open for as long as their objects are there:
    // the window object is disposed of before they are closed.
    const wanted = [_][*:0]const u8{
        ct.CLICKTAB_LIBRARY, pgc.PAGE_LIBRARY,  ig.INTEGER_LIBRARY,
        ch.CHOOSER_LIBRARY,  fgg.GAUGE_LIBRARY, tx.TEXT_LIBRARY,
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

    const shown = build(ib, first_tab) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(shown.layout, @ptrCast(&nominal));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Settings") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(nominal.domain.width + 40) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(nominal.domain.height + 8) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(shown.layout) },
        .{},
    }) orelse {
        ib.DisposeObject(shown.layout);
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

    var level: i32 = 0;
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
                    if (id == ID_STEP or id == ID_RESET) {
                        level = if (id == ID_RESET) 0 else @min(level + step_by, 100);
                        _ = ib.SetGadgetAttrsTagList(shown.gauge, window, &[_]TagItem{
                            .{ .tag = fgg.GAUGE_Level, .data = @bitCast(@as(isize, level)) },
                            .{},
                        });
                    }
                },
                else => {},
            }
        }
    }
}
