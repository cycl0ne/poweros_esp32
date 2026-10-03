// SPDX-License-Identifier: MIT
//! Styles: a screen whose gadgets are drawn in a style of its own. Built
//! against the SDK only.
//!
//!   Styles DARK/S
//!
//! It opens a public screen named `Styles` with a style of its own - flat
//! one-pixel borders, rounded corners, a face shaded from light to a little
//! darker, more room inside, a blue line round what the pointer is over, a
//! blue that a pressed button turns, every change taking a quarter of a
//! second - and makes
//! it the default public screen. DARK opens it dark instead: the screen's
//! pens dark, and a style that goes with them. Every
//! program that opens its window on the default public screen then opens
//! it there, drawn in that style, with nothing in the program changed:
//! `C:test/Gadgets`, `C:test/Layout` and `C:test/ListView` are the ones
//! to run.
//!
//! Ctrl-C puts the default public screen back and closes the screen as
//! soon as the last window on it has gone.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const sc = intuition.screens;
const style = intuition.style;
const ic = intuition.imageclass;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Styles";
const VERSION_STRING = "\x00$VER: Styles 1.0 (1.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DARK/S";
const arg_dark = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "The screen would not open\n";
const MSG_OPEN = "The default public screen is now Styles: run Gadgets, Layout or ListView. Ctrl-C ends it\n";
const MSG_WAITING = "Waiting for the windows on Styles to close\n";

const SCREEN_NAME = "Styles";

/// A button's face: light at the top, a little darker at the bottom.
const face = sdk.graphics.FillStyle{
    .stops = .{
        .{ .at = 0, .pen = 0xFFFA_FBFC },
        .{ .at = sdk.graphics.FILL_ONE, .pen = 0xFFD8_DCE2 },
        .{},
        .{},
    },
};

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
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

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The style: what differs from the system's default. Everything it does
    // not say - the bevels of the scroll bars, the title bar - stays as the
    // default draws it.
    const flat = [_]TagItem{
        // A gadget's body: one flat line, round corners, room inside.
        pair(style.STYLE_Part, style.PART_MAIN),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BorderRGB, 0xFF40_4850),
        pair(style.STYLE_BorderWidth, 1),
        pair(style.STYLE_Radius, 6),
        pair(style.STYLE_BackgroundFill, @intFromPtr(&face)),
        pair(style.STYLE_PaddingX, 6),
        pair(style.STYLE_PaddingY, 3),
        // Every change of look takes a quarter of a second.
        pair(style.STYLE_Transition, 250),
        // Under the pointer: the line turns blue.
        pair(style.STYLE_State, style.STATE_HOVERED),
        pair(style.STYLE_BorderRGB, 0xFF3A_6EA5),
        // Pressed and checked: filled with the blue, the line the same.
        pair(style.STYLE_State, style.STATE_PRESSED),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BackgroundRGB, 0xFF3A_6EA5),
        pair(style.STYLE_TextRGB, 0xFFFF_FFFF),
        pair(style.STYLE_State, style.STATE_CHECKED),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BackgroundRGB, 0xFF3A_6EA5),
        pair(style.STYLE_TextRGB, 0xFFFF_FFFF),
        // The plain frame round a field: less rounded than a button.
        pair(style.STYLE_Part, ic.PART_FRAME_PLAIN),
        pair(style.STYLE_Radius, 3),
        pair(style.STYLE_PaddingX, 3),
        pair(style.STYLE_PaddingY, 2),
        // A checked box is filled with the blue, as a pressed button is,
        // so its tick is white; a radio button's dot is the blue.
        pair(style.STYLE_Part, ic.PART_CHECKMARK),
        pair(style.STYLE_BackgroundRGB, 0xFFFF_FFFF),
        pair(style.STYLE_Part, ic.PART_RADIOMARK),
        pair(style.STYLE_BackgroundRGB, 0xFF3A_6EA5),
        // A field: white, square, its line the body's.
        pair(style.STYLE_Part, ic.PART_FIELD),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BorderRGB, 0xFF88_90A0),
        pair(style.STYLE_BorderWidth, 1),
        pair(style.STYLE_BackgroundRGB, 0xFFFF_FFFF),
        pair(style.STYLE_Transition, 250),
        pair(style.STYLE_State, style.STATE_HOVERED),
        pair(style.STYLE_BorderRGB, 0xFF3A_6EA5),
        pair(style.STYLE_State, style.STATE_FOCUSED),
        pair(style.STYLE_BorderRGB, 0xFF3A_6EA5),
        pair(style.STYLE_BackgroundRGB, 0xFFE8_F0FF),
        // A slider's channel and knob: round, the knob the blue.
        pair(style.STYLE_Part, style.PART_TRACK),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BorderRGB, 0xFF88_90A0),
        pair(style.STYLE_BackgroundRGB, 0xFFF4_F5F7),
        pair(style.STYLE_Radius, 5),
        pair(style.STYLE_Part, style.PART_KNOB),
        pair(style.STYLE_Border, style.BORDER_NONE),
        pair(style.STYLE_BackgroundRGB, 0xFF3A_6EA5),
        pair(style.STYLE_Radius, 4),
        // The active window's title bar in the blue with white writing; an
        // inactive one a quiet grey.
        pair(style.STYLE_Part, style.PART_TITLE),
        pair(style.STYLE_BackgroundRGB, 0xFF3A_6EA5),
        pair(style.STYLE_TextRGB, 0xFFFF_FFFF),
        pair(style.STYLE_Part, ic.PART_TITLE_INACTIVE),
        pair(style.STYLE_BackgroundRGB, 0xFFC8_CCD2),
        pair(style.STYLE_TextRGB, 0xFF40_4850),
        // The screen's bar dark, its menus white with a thin grey edge.
        pair(style.STYLE_Part, ic.PART_SCREEN_BAR),
        pair(style.STYLE_BackgroundRGB, 0xFF2B_3038),
        pair(style.STYLE_TextRGB, 0xFFF0_F2F5),
        pair(style.STYLE_BorderRGB, 0xFF10_1418),
        pair(style.STYLE_Part, ic.PART_MENU),
        pair(style.STYLE_BackgroundRGB, 0xFFFF_FFFF),
        pair(style.STYLE_BorderRGB, 0xFF88_90A0),
        pair(style.STYLE_BorderWidth, 1),
        pair(style.STYLE_TextRGB, 0xFF20_2428),
        // A list's chosen line and a bar's level, in the theme's blue.
        pair(style.STYLE_Part, style.PART_SELECTION),
        pair(style.STYLE_BackgroundRGB, 0xFF2F_6FD0),
        pair(style.STYLE_TextRGB, 0xFFFF_FFFF),
        pair(style.STYLE_Part, style.PART_INDICATOR),
        pair(style.STYLE_BackgroundRGB, 0xFF2F_6FD0),
        pair(style.STYLE_TextRGB, 0xFFFF_FFFF),
        // A framed group: a lighter line, rounder corners.
        pair(style.STYLE_Part, style.PART_GROUP),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BorderRGB, 0xFF88_90A0),
        pair(style.STYLE_BorderWidth, 1),
        pair(style.STYLE_Radius, 8),
        pair(style.STYLE_PaddingX, 6),
        pair(style.STYLE_PaddingY, 4),
        .{},
    };

    // The dark look: the screen's own pens dark - the inside of every
    // window, the bar, the default's bevels - and a style over them in the
    // same colours.
    const dark_pens = [sc.NUMDRIPENS]sdk.graphics.Pen{
        0xFF10_1214, // DETAILPEN
        0xFFE8_EAED, // BLOCKPEN
        0xFFE8_EAED, // TEXTPEN
        0xFF5A_6068, // SHINEPEN
        0xFF10_1214, // SHADOWPEN
        0xFF3A_6EA5, // FILLPEN
        0xFFFF_FFFF, // FILLTEXTPEN
        0xFF2B_3038, // BACKGROUNDPEN
        0xFFFF_FFFF, // HIGHLIGHTTEXTPEN
        0xFFE8_EAED, // BARDETAILPEN
        0xFF1E_2228, // BARBLOCKPEN
        0xFF10_1214, // BARTRIMPEN
    };
    const dark = [_]TagItem{
        pair(style.STYLE_Part, style.PART_MAIN),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BorderRGB, 0xFF5A_6068),
        pair(style.STYLE_BorderWidth, 1),
        pair(style.STYLE_Radius, 6),
        pair(style.STYLE_BackgroundRGB, 0xFF3A_4048),
        pair(style.STYLE_PaddingX, 6),
        pair(style.STYLE_PaddingY, 3),
        pair(style.STYLE_State, style.STATE_HOVERED),
        pair(style.STYLE_BorderRGB, 0xFF6F_A0D8),
        pair(style.STYLE_State, style.STATE_PRESSED),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BackgroundRGB, 0xFF3A_6EA5),
        pair(style.STYLE_State, style.STATE_CHECKED),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BackgroundRGB, 0xFF3A_6EA5),
        pair(style.STYLE_Part, ic.PART_FRAME_PLAIN),
        pair(style.STYLE_Radius, 3),
        pair(style.STYLE_PaddingX, 3),
        pair(style.STYLE_PaddingY, 2),
        pair(style.STYLE_Part, ic.PART_CHECKMARK),
        pair(style.STYLE_BackgroundRGB, 0xFFFF_FFFF),
        pair(style.STYLE_Part, ic.PART_FIELD),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BorderRGB, 0xFF5A_6068),
        pair(style.STYLE_BorderWidth, 1),
        pair(style.STYLE_BackgroundRGB, 0xFF1E_2228),
        pair(style.STYLE_State, style.STATE_HOVERED),
        pair(style.STYLE_BorderRGB, 0xFF6F_A0D8),
        pair(style.STYLE_State, style.STATE_FOCUSED),
        pair(style.STYLE_BorderRGB, 0xFF6F_A0D8),
        pair(style.STYLE_BackgroundRGB, 0xFF16_1A20),
        pair(style.STYLE_Part, style.PART_TRACK),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BorderRGB, 0xFF5A_6068),
        pair(style.STYLE_BackgroundRGB, 0xFF1E_2228),
        pair(style.STYLE_Radius, 5),
        pair(style.STYLE_Part, style.PART_KNOB),
        pair(style.STYLE_Border, style.BORDER_NONE),
        pair(style.STYLE_BackgroundRGB, 0xFF6F_A0D8),
        pair(style.STYLE_Radius, 4),
        pair(style.STYLE_Part, ic.PART_MENU),
        pair(style.STYLE_BorderRGB, 0xFF5A_6068),
        pair(style.STYLE_BorderWidth, 1),
        pair(style.STYLE_Part, style.PART_GROUP),
        pair(style.STYLE_Border, style.BORDER_FLAT),
        pair(style.STYLE_BorderRGB, 0xFF5A_6068),
        pair(style.STYLE_BorderWidth, 1),
        pair(style.STYLE_Radius, 8),
        pair(style.STYLE_PaddingX, 6),
        pair(style.STYLE_PaddingY, 4),
        .{},
    };
    const is_dark = argv[arg_dark] != 0;

    const screen = ib.OpenScreenTagList(&[_]TagItem{
        pair(sc.SA_PubName, @intFromPtr(SCREEN_NAME)),
        pair(sc.SA_Title, if (is_dark) @intFromPtr("Styles: the same gadgets, in the dark") else @intFromPtr("Styles: the same gadgets, another look")),
        pair(sc.SA_LikeWorkbench, 1),
        pair(sc.SA_Style, if (is_dark) @intFromPtr(&dark) else @intFromPtr(&flat)),
        if (is_dark) pair(sc.SA_Pens, @intFromPtr(&dark_pens)) else .{ .tag = sdk.utility.TAG_IGNORE, .data = 0 },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    _ = ib.PubScreenStatus(screen, 0);
    ib.SetDefaultPubScreen(SCREEN_NAME);
    _ = Printf(dl, MSG_OPEN, .{});

    _ = sys.Wait(exec.SIGBREAKF_CTRL_C);

    // Nobody new, then the default back, then closed once the last window
    // on it has gone.
    _ = ib.PubScreenStatus(screen, sc.PSNF_PRIVATE);
    ib.SetDefaultPubScreen(null);
    var told = false;
    while (!ib.CloseScreen(screen)) {
        if (!told) _ = Printf(dl, MSG_WAITING, .{});
        told = true;
        dl.Delay(50);
    }
    return dos.RETURN_OK;
}
