// SPDX-License-Identifier: MIT
//! Layout: a window whose gadgets are placed by layoutgclass. Built
//! against the SDK only.
//!
//!   Layout MARGIN/N,SPACING/N,GRID/S
//!
//! It opens a window on the default public screen through windowclass,
//! holding one layout: a column of a line to type a name in and a slider,
//! each labelled; a row of three buttons that takes whatever height is
//! spare; a button kept to its own width in the middle of the column and
//! one at its right end (`CHILDA_Align`); and OK and Cancel along the
//! bottom, kept at least two lines of
//! the screen's font high so that a finger finds them. Nothing in it is
//! given a place: the window opens in the middle of the screen at half its
//! size (a `WA_` tag handed on to the window) or the layout's nominal
//! size, whichever is larger, and everything is placed again as the window
//! is sized - which it cannot be smaller than the layout fits in. The rows
//! of buttons wrap: sized narrower than a row's buttons, the ones that do
//! not fit go onto a line beneath.
//!
//! GRID lays the same window out as a grid of two columns: Name and
//! Volume side by side, Place and Balance under them, each column's
//! fields after its own labels and lined up with the row above; the
//! buttons across both columns.
//!
//! Every gadget let go is printed with its ID - the button itself, not
//! the layout it is in - as WM_HANDLEINPUT answers it. OK prints the name
//! and ends it; Cancel, the close gadget or Ctrl-C end it too. MARGIN and
//! SPACING are the layout's, in pixels (6 and 4 unless given).

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const sc = intuition.screens;
const wn = intuition.windows;
const gc = intuition.gadgetclass;
const pg = intuition.propgclass;
const lg = intuition.layoutgclass;
const wc = intuition.windowclass;
const classusr = intuition.classusr;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Object = intuition.Object;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Layout";
const VERSION_STRING = "\x00$VER: Layout 1.3 (2.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "MARGIN/N,SPACING/N,GRID/S";
const arg_margin = 0;
const arg_spacing = 1;
const arg_grid = 2;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOMEMORY = "No memory for the gadgets\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Size the window: everything in it is placed again. OK, Cancel, the close gadget or Ctrl-C end it\n";
const MSG_GADGET = "Gadget %lu: %s\n";
const MSG_SLIDER = "Gadget %lu: %s at %lu\n";
const MSG_NAME = "Name: \"%s\"\n";

const ID_NAME = 1;
const ID_VOLUME = 2;
const ID_ONE = 3;
const ID_TWO = 4;
const ID_THREE = 5;
const ID_OK = 6;
const ID_CANCEL = 7;
const ID_CENTRED = 8;
const ID_HELP = 9;
const ID_PLACE = 10;
const ID_BALANCE = 11;

const default_margin = 6;
const default_spacing = 4;

/// The gadgets of the window, made here and all given to the layout: its
/// disposal is theirs.
const Gadgets = struct {
    name: *Object,
    volume: *Object,
    layout: *Object,
};

fn button(ib: *IntuitionBase, text: [*:0]const u8, id: usize) ?*Object {
    return ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

/// A row of gadgets, all as tall as the row and none narrower than
/// `least` (0 for their own), that wraps onto a second line when the
/// window is too narrow for it; null, with every one of them freed, when
/// one could not be made or taken.
fn row(ib: *IntuitionBase, spacing: usize, least: u32, children: []const ?*Object) ?*Object {
    var whole = true;
    for (children) |child| whole = whole and child != null;
    const layout = if (whole) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_HORIZ },
        .{ .tag = lg.LAYOUTA_Spacing, .data = spacing },
        .{ .tag = lg.LAYOUTA_Wrap, .data = 1 },
        .{},
    }) else null;
    for (children, 0..) |child, i| {
        if (layout) |into| {
            const add = [_]TagItem{
                .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(child) },
                .{ .tag = if (least != 0) lg.CHILDA_MinWidth else sdk.utility.TAG_IGNORE, .data = least },
                .{},
            };
            if (ib.SetAttrsTagList(into, &add) != 0) continue;
            // Not taken: it and the rest are still ours, what went before
            // goes with the layout.
            for (children[i..]) |rest| ib.DisposeObject(rest);
            ib.DisposeObject(into);
            return null;
        }
        ib.DisposeObject(child);
    }
    return layout;
}

/// The whole of it. A gadget that could not be made takes the others
/// with it: whatever the layout already holds goes when it does, and the
/// rest are freed here.
fn build(ib: *IntuitionBase, line: u32, margin: usize, spacing: usize, grid: bool) ?Gadgets {
    const name = ib.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.STRINGA_MaxChars, .data = 64 },
        .{ .tag = gc.GA_ID, .data = ID_NAME },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{},
    });
    const volume = ib.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = pg.PGA_Total, .data = 100 },
        .{ .tag = pg.PGA_Visible, .data = 10 },
        .{ .tag = gc.GA_Width, .data = 100 },
        .{ .tag = gc.GA_Height, .data = line },
        .{ .tag = gc.GA_ID, .data = ID_VOLUME },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
    // Wide enough for a finger each: the row the window wraps first.
    const middle = row(ib, spacing, 6 * line, &.{ button(ib, "One", ID_ONE), button(ib, "Two", ID_TWO), button(ib, "Three", ID_THREE) });
    const bottom = row(ib, spacing, 0, &.{ button(ib, "OK", ID_OK), button(ib, "Cancel", ID_CANCEL) });
    const centred = button(ib, "Centred", ID_CENTRED);
    const help = button(ib, "Help", ID_HELP);
    // The grid's second row.
    const place = if (grid) ib.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.STRINGA_MaxChars, .data = 64 },
        .{ .tag = gc.GA_ID, .data = ID_PLACE },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.GA_TabCycle, .data = 1 },
        .{},
    }) else null;
    const balance = if (grid) ib.NewObjectTagList(null, classusr.PROPGCLASS, &[_]TagItem{
        .{ .tag = pg.PGA_Freedom, .data = pg.FREEHORIZ },
        .{ .tag = pg.PGA_Total, .data = 100 },
        .{ .tag = pg.PGA_Visible, .data = 10 },
        .{ .tag = pg.PGA_Top, .data = 45 },
        .{ .tag = gc.GA_Width, .data = 100 },
        .{ .tag = gc.GA_Height, .data = line },
        .{ .tag = gc.GA_ID, .data = ID_BALANCE },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    }) else null;
    if (name == null or volume == null or middle == null or bottom == null or centred == null or help == null or
        (grid and (place == null or balance == null)))
    {
        ib.DisposeObject(name);
        ib.DisposeObject(volume);
        ib.DisposeObject(middle);
        ib.DisposeObject(bottom);
        ib.DisposeObject(centred);
        ib.DisposeObject(help);
        ib.DisposeObject(place);
        ib.DisposeObject(balance);
        return null;
    }
    const grid_tags = [_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = margin },
        .{ .tag = lg.LAYOUTA_Spacing, .data = spacing },
        .{ .tag = lg.LAYOUTA_Orientation, .data = lg.LORIENT_GRID },
        .{ .tag = lg.LAYOUTA_Columns, .data = 2 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(name) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Name") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(volume) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Volume") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(place) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Place") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(balance) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Balance") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(middle) },
        .{ .tag = lg.CHILDA_ColumnSpan, .data = 2 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(centred) },
        .{ .tag = lg.CHILDA_ColumnSpan, .data = 2 },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.CHILDA_Align, .data = lg.CALIGN_HCENTRE },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(help) },
        .{ .tag = lg.CHILDA_ColumnSpan, .data = 2 },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.CHILDA_Align, .data = lg.CALIGN_RIGHT },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(bottom) },
        .{ .tag = lg.CHILDA_ColumnSpan, .data = 2 },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.CHILDA_MinHeight, .data = 2 * line },
        .{},
    };
    const layout = (if (grid) ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &grid_tags) else ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        .{ .tag = lg.LAYOUTA_Margin, .data = margin },
        .{ .tag = lg.LAYOUTA_Spacing, .data = spacing },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(name) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Name") },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(volume) },
        .{ .tag = lg.CHILDA_Label, .data = @intFromPtr("Volume") },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(middle) },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(centred) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.CHILDA_Align, .data = lg.CALIGN_HCENTRE },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(help) },
        .{ .tag = lg.CHILDA_WeightWidth, .data = 0 },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.CHILDA_Align, .data = lg.CALIGN_RIGHT },
        .{ .tag = lg.LAYOUTA_AddChild, .data = @intFromPtr(bottom) },
        .{ .tag = lg.CHILDA_WeightHeight, .data = 0 },
        .{ .tag = lg.CHILDA_MinHeight, .data = 2 * line },
        .{},
    })) orelse {
        ib.DisposeObject(name);
        ib.DisposeObject(volume);
        ib.DisposeObject(middle);
        ib.DisposeObject(bottom);
        ib.DisposeObject(centred);
        ib.DisposeObject(help);
        ib.DisposeObject(place);
        ib.DisposeObject(balance);
        return null;
    };
    return .{ .name = name.?, .volume = volume.?, .layout = layout };
}

fn screenAttr(ib: *IntuitionBase, screen: *intuition.Screen, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    ib.GetScreenAttrs(screen, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
    return value;
}

fn nameOf(id: usize) [*:0]const u8 {
    return switch (id) {
        ID_NAME => "Name",
        ID_ONE => "One",
        ID_TWO => "Two",
        ID_THREE => "Three",
        ID_OK => "OK",
        ID_CANCEL => "Cancel",
        ID_CENTRED => "Centred",
        ID_HELP => "Help",
        ID_PLACE => "Place",
        else => "?",
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const margin: usize = if (argv[arg_margin] != 0) @intCast(@as(*const i32, @ptrFromInt(argv[arg_margin])).*) else default_margin;
    const spacing: usize = if (argv[arg_spacing] != 0) @intCast(@as(*const i32, @ptrFromInt(argv[arg_spacing])).*) else default_spacing;

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);
    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, graphics.GRAPHICS_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    // A line of the screen's font: how tall the slider is, and half of
    // how tall the buttons at the bottom are at the least.
    var line: u32 = 8;
    if (screenAttr(ib, screen, sc.SA_Font) != 0) {
        var extent = graphics.FontExtent{};
        gb.FontExtent(@ptrFromInt(screenAttr(ib, screen, sc.SA_Font)), &extent);
        line = @intCast(extent.height);
    }

    const gadgets = build(ib, line, margin, spacing, argv[arg_grid] != 0) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };

    // Half the screen, or what the layout looks right at if that is more.
    var nominal = gc.GpDomain{ .which = gc.GDOMAIN_NOMINAL };
    _ = ib.SendMessage(gadgets.layout, @ptrCast(&nominal));
    const width: usize = @intCast(@max(nominal.domain.width, @as(i32, @intCast(screenAttr(ib, screen, sc.SA_Width) / 2))));
    const height: usize = @intCast(@max(nominal.domain.height, @as(i32, @intCast(screenAttr(ib, screen, sc.SA_Height) / 2))));
    const object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Layout") },
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_InnerWidth, .data = width },
        .{ .tag = wn.WA_InnerHeight, .data = height },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wc.WINDOWA_Layout, .data = @intFromPtr(gadgets.layout) },
        .{},
    }) orelse {
        ib.DisposeObject(gadgets.layout);
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    };
    // The window, the layout and every gadget in it.
    defer ib.DisposeObject(object);

    var open = wc.WmOpen{};
    const window: *intuition.Window = @ptrFromInt(ib.SendMessage(object, @ptrCast(&open)));
    if (@intFromPtr(window) == 0) {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, MSG_HELLO, .{});

    var handle = wc.WmHandleInput{};
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
                    switch (id) {
                        ID_VOLUME => {
                            var at: usize = 0;
                            _ = ib.GetAttr(pg.PGA_Top, gadgets.volume, &at);
                            _ = Printf(dl, MSG_SLIDER, .{ @as(u64, id), "Volume", @as(u64, at) });
                        },
                        ID_OK => {
                            var text: usize = 0;
                            _ = ib.GetAttr(gc.STRINGA_TextVal, gadgets.name, &text);
                            const shown: [*:0]const u8 = if (text != 0) @ptrFromInt(text) else "";
                            _ = Printf(dl, MSG_NAME, .{shown});
                            return dos.RETURN_OK;
                        },
                        ID_CANCEL => return dos.RETURN_OK,
                        else => _ = Printf(dl, MSG_GADGET, .{ @as(u64, id), nameOf(id) }),
                    }
                },
                else => {},
            }
        }
    }
}
