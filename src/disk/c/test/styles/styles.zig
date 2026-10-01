// SPDX-License-Identifier: MIT
//! Styles: a screen whose gadgets are drawn in a style of its own. Built
//! against the SDK only.
//!
//!   Styles
//!
//! It opens a public screen named `Styles` with a style of its own - flat
//! one-pixel borders, rounded corners, more room inside, a blue that a
//! pressed button turns - and makes it the default public screen. Every
//! program that opens its window on the default public screen then opens
//! it there, drawn in that style, with nothing in the program changed:
//! `C:test/Gadgets` and `C:test/Layout` are the ones to run.
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

const template = "";

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "The screen would not open\n";
const MSG_OPEN = "The default public screen is now Styles: run Gadgets or Layout. Ctrl-C ends it\n";
const MSG_WAITING = "Waiting for the windows on Styles to close\n";

const SCREEN_NAME = "Styles";

fn pair(t: sdk.utility.Tag, data: usize) TagItem {
    return .{ .tag = t, .data = data };
}

/// The style: what differs from the system's default. Everything it does
/// not say - the bevels of the scroll bars, the title bar - stays as the
/// default draws it.
const flat = [_]TagItem{
    // A gadget's body: one flat line, round corners, room inside.
    pair(style.STYLE_Part, style.PART_MAIN),
    pair(style.STYLE_Border, style.BORDER_FLAT),
    pair(style.STYLE_BorderRGB, 0xFF40_4850),
    pair(style.STYLE_BorderWidth, 1),
    pair(style.STYLE_Radius, 6),
    pair(style.STYLE_BackgroundRGB, 0xFFE8_EAED),
    pair(style.STYLE_PaddingX, 6),
    pair(style.STYLE_PaddingY, 3),
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

    const screen = ib.OpenScreenTagList(&[_]TagItem{
        pair(sc.SA_PubName, @intFromPtr(SCREEN_NAME)),
        pair(sc.SA_Title, @intFromPtr("Styles: the same gadgets, another look")),
        pair(sc.SA_LikeWorkbench, 1),
        pair(sc.SA_Style, @intFromPtr(&flat)),
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
