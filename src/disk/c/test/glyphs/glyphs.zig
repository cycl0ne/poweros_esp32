// SPDX-License-Identifier: MIT
//! Glyphs: every picture command.image draws, at one size, enabled and
//! disabled. Built against the SDK only.
//!
//!   Glyphs SIZE/N,DARK/S,NOWINDOW/S
//!
//! It opens a window on the default public screen with two panels, each
//! every picture from `CMD_NEW` to `CMD_LAST` in a grid: the first as a
//! button shows it, the second disabled. SIZE is how big each is, 16 to
//! 96 and 32 without; at 16 they have no shading, gloss or shadow. Run it
//! at 16, 24, 32 and 48 to see them as a menu, a small and a large button
//! and the dock would.
//!
//! DARK draws them on a dark ground with light ink, as a dark screen
//! would: the window's background and text pens are its own, in a copy of
//! the screen's DrawInfo, and the pictures follow them.
//!
//! The window stays until the close gadget or Ctrl-C. NOWINDOW draws
//! nothing and only says how many pictures there are.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ic = intuition.imageclass;
const sc = intuition.screens;
const command = sdk.images.command;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const RastPort = graphics.RastPort;
const Pen = graphics.Pen;

pub const COMMAND_NAME = "Glyphs";
const VERSION_STRING = "\x00$VER: Glyphs 1.0 (28.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SIZE/N,DARK/S,NOWINDOW/S";
const arg_size = 0;
const arg_dark = 1;
const arg_nowindow = 2;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display, or it shows another screen\n";
const MSG_NOWINDOW = "No window - the screen would not open one that size\n";
const MSG_NOIMAGE = "No command.image object\n";
const MSG_GLYPHS = "%lu pictures, at %lu pixels\n";
const MSG_WAITING = "The close gadget or Ctrl-C closes the window\n";

/// The pictures there are.
const count = command.CMD_LAST - command.CMD_NEW + 1;
/// Room between two pictures, and round the panels.
const gap = 8;
const margin = 10;
/// A heading's line.
const heading_h = 18;

/// The pens of DARK: a dark ground and light ink on it.
const dark_ground: Pen = 0xFF2A_2E35;
const dark_ink: Pen = 0xFFE6_E8EB;

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
    const size: i32 = if (argv[arg_size] != 0) @intCast(@min(@max(@as(*const i32, @ptrFromInt(argv[arg_size])).*, 16), 96)) else 32;

    if (argv[arg_nowindow] != 0) {
        _ = Printf(dl, MSG_GLYPHS, .{ @as(u64, count), @as(u64, @intCast(size)) });
        return dos.RETURN_OK;
    }

    const gfx_lib = sys.OpenLibrary(graphics.GRAPHICSNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{graphics.GRAPHICSNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(gfx_lib);
    const gb: *GraphicsBase = @ptrCast(gfx_lib);

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    const command_lib = sys.OpenLibrary(command.COMMAND_LIBRARY, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{command.COMMAND_LIBRARY});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(command_lib);
    const image = ib.NewObjectTagList(null, command.COMMAND_CLASS, null) orelse {
        _ = Printf(dl, MSG_NOIMAGE, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.DisposeObject(image);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);
    const screen_dri = ib.GetScreenDrawInfo(screen);
    defer ib.FreeScreenDrawInfo(screen, screen_dri);

    // As many to a row as the screen has room for, from 4 to 9.
    var ask_width: usize = 0;
    ib.GetScreenAttrs(screen, &[_]TagItem{ .{ .tag = sc.SA_Width, .data = @intFromPtr(&ask_width) }, .{} });
    const cell = size + gap;
    const room: i32 = @divTrunc(@as(i32, @intCast(ask_width)) - 2 * margin - 40, cell);
    const columns: i32 = @min(@max(room, 4), 9);
    const rows: i32 = @divTrunc(@as(i32, count) + columns - 1, columns);
    const panel_h = heading_h + rows * cell;
    const inner_w = @max(2 * margin + columns * cell - gap, 200);
    const inner_h = 2 * margin + 2 * panel_h + gap;

    const window_tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 20 },
        .{ .tag = wn.WA_Top, .data = 18 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(inner_w) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(inner_h) },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Glyphs") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_SmartRefresh, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    };
    const w = ib.OpenWindowTagList(&window_tags) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);

    const rp: *RastPort = @ptrFromInt(wattr(ib, w, wn.WA_RastPort));
    const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
    const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop));

    // DARK: the screen's pens, but for the ground and the ink.
    var pens: [sc.NUMDRIPENS]Pen = undefined;
    for (&pens, 0..) |*p, i| p.* = screen_dri.pens[i];
    var dark_dri = screen_dri.*;
    pens[sc.BACKGROUNDPEN] = dark_ground;
    pens[sc.TEXTPEN] = dark_ink;
    dark_dri.pens = &pens;
    dark_dri.num_pens = sc.NUMDRIPENS;
    const dri: *sc.DrawInfo = if (argv[arg_dark] != 0) &dark_dri else screen_dri;

    pen(gb, rp, dri.pens[sc.BACKGROUNDPEN]);
    gb.RectFill(rp, &.{ .min_x = left, .min_y = top, .max_x = left + inner_w, .max_y = top + inner_h });

    var y = top + margin;
    panel(ib, gb, rp, dri, image, left + margin, y, size, columns, "As a button shows them", ic.IDS_NORMAL);
    y += panel_h + gap;
    panel(ib, gb, rp, dri, image, left + margin, y, size, columns, "Disabled", ic.IDS_DISABLED);

    _ = Printf(dl, MSG_WAITING, .{});

    var open = true;
    while (open) {
        const got = ib.WaitIMsg(w, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        while (ib.GetIMsg(w)) |im| {
            const class = im.class;
            ib.ReplyIMsg(im);
            if (class == wn.IDCMP_CLOSEWINDOW) open = false;
        }
    }
    return dos.RETURN_OK;
}

/// A heading, and under it every picture in `state`, `columns` to a row.
fn panel(ib: *IntuitionBase, gb: *GraphicsBase, rp: *RastPort, dri: *sc.DrawInfo, image: *intuition.Object, x0: i32, y0: i32, size: i32, columns: i32, heading: []const u8, state: u32) void {
    pen(gb, rp, dri.pens[sc.TEXTPEN]);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
    gb.Move(rp, x0, y0 + 10);
    gb.Text(rp, heading.ptr, @intCast(heading.len));
    var glyph: u32 = command.CMD_NEW;
    while (glyph <= command.CMD_LAST) : (glyph += 1) {
        const at: i32 = @intCast(glyph - command.CMD_NEW);
        _ = ib.SetAttrsTagList(image, &[_]TagItem{ .{ .tag = command.COMMAND_Glyph, .data = glyph }, .{} });
        var draw = ic.ImpDraw{
            .method_id = ic.IM_DRAWFRAME,
            .rast_port = rp,
            .offset = .{ .x = x0 + @mod(at, columns) * (size + gap), .y = y0 + heading_h + @divTrunc(at, columns) * (size + gap) },
            .state = state,
            .draw_info = dri,
            .dimensions = .{ .width = size, .height = size },
        };
        _ = ib.SendMessage(image, @ptrCast(&draw));
    }
}

/// The RastPort's pen, set in one line rather than four.
fn pen(gb: *GraphicsBase, rp: *RastPort, ink: Pen) void {
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = ink }, .{} });
}

/// One of the window's numbers.
fn wattr(ib: *IntuitionBase, window: *intuition.Window, tag: sdk.utility.Tag) usize {
    var storage: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&storage) }, .{} });
    return storage;
}
