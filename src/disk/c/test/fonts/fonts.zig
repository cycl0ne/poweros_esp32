// SPDX-License-Identifier: MIT
//! Fonts: every glyph of the ROM's fonts, printed and drawn. Built
//! against the SDK only.
//!
//!   Fonts SIZE/K/N,NOWINDOW/S
//!
//! It prints the character set to its console, 32 characters to a line:
//! 32 to 127 and then 160 to 255, so the console's own font shows every
//! letter it has. 128 to 159 are left out; a console reads some of them
//! as control codes.
//!
//! Then it opens a window on the default public screen and draws the same
//! lines once in each size of `pospaz.font` the ROM has (8 and 16), or only
//! SIZE when that is given, each under a line naming it in that font. The
//! window stays until the close gadget or Ctrl-C. NOWINDOW prints and
//! stops there.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const RastPort = graphics.RastPort;

pub const COMMAND_NAME = "Fonts";
const VERSION_STRING = "\x00$VER: Fonts 1.0 (24.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SIZE/K/N,NOWINDOW/S";
const arg_size = 0;
const arg_nowindow = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display, or it shows another screen\n";
const MSG_NOWINDOW = "No window - the screen would not open one that size\n";
const MSG_NOFONT = "No pospaz.font %d in the ROM\n";
const MSG_LINE = "%3d  %s\n";
const MSG_WAITING = "The close gadget or Ctrl-C closes the window\n";

/// The heights the ROM has.
const rom_sizes = [_]u32{ 8, 16 };

/// Characters a line, and the first character of each line: 32 to 127,
/// then 160 to 255.
const per_line = 32;
const line_starts = [_]u8{ 32, 64, 96, 160, 192, 224 };

/// Room round the text inside the window, and between two fonts.
const margin = 8;
const gap = 6;

/// One line of the set: `per_line` characters from `first`, NUL-ended.
/// 127 is not drawn by a console, so it is shown as a space there.
fn lineOf(first: u8, for_console: bool) [per_line + 1]u8 {
    var line: [per_line + 1]u8 = undefined;
    for (0..per_line) |i| {
        const code: u8 = first + @as(u8, @intCast(i));
        line[i] = if (for_console and code == 127) ' ' else code;
    }
    line[per_line] = 0;
    return line;
}

fn wattr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &ask);
    return value;
}

fn set(gb: *GraphicsBase, rp: *RastPort, tag: u32, data: usize) void {
    const tags = [_]TagItem{ .{ .tag = tag, .data = data }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

/// How tall one font's block is: its name and the six lines, a row apart.
fn blockHeight(height: u32) i32 {
    return @intCast((line_starts.len + 1) * (height + 2));
}

/// The name line and the six lines of the set in `font`, from `top`.
fn drawBlock(gb: *GraphicsBase, rp: *RastPort, font: *graphics.TextFont, height: u32, left: i32, top: i32) void {
    graphics.SetFont(gb, rp, font);
    var baseline_of: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline_of) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    const baseline: i32 = @intCast(baseline_of);
    const row: i32 = @intCast(height + 2);

    var name: [24]u8 = undefined;
    const name_len = nameLine(&name, height);
    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(255, 200, 80));
    gb.Move(rp, left, top + baseline);
    gb.Text(rp, &name, name_len);

    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(255, 255, 255));
    for (line_starts, 0..) |first, i| {
        const line = lineOf(first, false);
        gb.Move(rp, left, top + row * @as(i32, @intCast(i + 1)) + baseline);
        gb.Text(rp, &line, per_line);
    }
}

/// "pospaz.font 8" or "pospaz.font 16" into `out`; answers its length.
fn nameLine(out: *[24]u8, height: u32) u32 {
    const prefix = "pospaz.font ";
    for (prefix, 0..) |c, i| out[i] = c;
    var at: u32 = prefix.len;
    if (height >= 10) {
        out[at] = '0' + @as(u8, @intCast(height / 10));
        at += 1;
    }
    out[at] = '0' + @as(u8, @intCast(height % 10));
    return at + 1;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    for (line_starts) |first| {
        const line = lineOf(first, true);
        _ = Printf(dl, MSG_LINE, .{ @as(u32, first), @as([*:0]const u8, @ptrCast(&line)) });
    }
    if (argv[arg_nowindow] != 0) return dos.RETURN_OK;

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

    // The sizes to show: SIZE alone, or all the ROM has.
    var sizes: [rom_sizes.len]u32 = undefined;
    var fonts: [rom_sizes.len]?*graphics.TextFont = @splat(null);
    var count: usize = 0;
    if (argv[arg_size] != 0) {
        sizes[0] = @bitCast(@as(*const i32, @ptrFromInt(argv[arg_size])).*);
        count = 1;
    } else {
        for (rom_sizes, 0..) |size, i| sizes[i] = size;
        count = rom_sizes.len;
    }
    defer for (fonts[0..count]) |font| if (font) |f| gb.CloseFont(f);

    var inner_h: i32 = margin;
    for (sizes[0..count], 0..) |size, i| {
        fonts[i] = gb.OpenFont(graphics.POSPAZNAME, size);
        if (fonts[i] == null) {
            _ = Printf(dl, MSG_NOFONT, .{size});
            continue;
        }
        inner_h += blockHeight(size) + gap;
    }
    if (inner_h == margin) return dos.RETURN_WARN;
    inner_h += margin - gap;
    const inner_w: i32 = per_line * 8 + 2 * margin;

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_WARN;
    };
    defer ib.UnlockPubScreen(null, screen);

    const window_tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 40 },
        .{ .tag = wn.WA_Top, .data = 30 },
        .{ .tag = wn.WA_InnerWidth, .data = @intCast(inner_w) },
        .{ .tag = wn.WA_InnerHeight, .data = @intCast(inner_h) },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Fonts") },
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
    const port: *exec.MsgPort = @ptrFromInt(wattr(ib, w, wn.WA_UserPort));
    const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
    const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop));
    const shown_w: i32 = @intCast(wattr(ib, w, wn.WA_InnerWidth));
    const shown_h: i32 = @intCast(wattr(ib, w, wn.WA_InnerHeight));

    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(0, 0, 0));
    gb.RectFill(rp, &.{ .min_x = left, .min_y = top, .max_x = left + shown_w - 1, .max_y = top + shown_h - 1 });
    set(gb, rp, graphics.RPTAG_DrMd, graphics.DRMD_JAM1);

    var y: i32 = top + margin;
    for (sizes[0..count], 0..) |size, i| {
        const font = fonts[i] orelse continue;
        drawBlock(gb, rp, font, size, left + margin, y);
        y += blockHeight(size) + gap;
    }

    _ = Printf(dl, MSG_WAITING, .{});
    var open = true;
    while (open) {
        const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
        while (sys.GetMsg(port)) |m| {
            const im: *intuition.IntuiMessage = @ptrCast(@alignCast(m));
            const class = im.class;
            sys.ReplyMsg(m);
            if (class == wn.IDCMP_CLOSEWINDOW) open = false;
        }
    }
    return dos.RETURN_OK;
}
