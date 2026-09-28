// SPDX-License-Identifier: MIT
//! Fonts: every glyph of the ROM's fonts, printed and drawn. Built
//! against the SDK only.
//!
//!   Fonts SIZE/K/N,NOWINDOW/S,TIMES/S,FILE/K
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
//!
//! FILE draws a font from a size file instead - `FONTS:spleen/16` - read
//! with dos, checked whole and sound, put on graphics' list with AddFont,
//! opened by its name as any font is, and taken off and freed at the end.
//!
//! TIMES then draws 2048 characters in each size, in JAM2 over what is
//! there, and prints how long that took by timer.device's E-clock - the
//! measure for a change to the text path.

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
const fontimage = graphics.fontimage;
const rdargs = dos.rdargs;
const timer = sdk.devices.timer;
const TimerBase = timer.TimerBase;

pub const COMMAND_NAME = "Fonts";
const VERSION_STRING = "\x00$VER: Fonts 1.2 (28.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SIZE/K/N,NOWINDOW/S,TIMES/S,FILE/K";
const arg_size = 0;
const arg_nowindow = 1;
const arg_times = 2;
const arg_file = 3;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display, or it shows another screen\n";
const MSG_NOWINDOW = "No window - the screen would not open one that size\n";
const MSG_NOFONT = "No pospaz.font %d in the ROM\n";
const MSG_LINE = "%3d  %s\n";
const MSG_NOTIMER = "No timer.device - no TIMES\n";
const MSG_TIME = "%s: %u characters in %u us\n";
const MSG_NOTFONT = "%s is not a whole font file\n";
const MSG_NOADD = "%s: graphics.library would not add it\n";
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

/// A font the window shows, and the line naming it.
const Shown = struct {
    font: ?*graphics.TextFont = null,
    height: u32 = 0,
    width: u32 = 0,
    label: [48:0]u8 = @splat(0),
};

/// The name line and the six lines of the set in `font`, from `top`.
fn drawBlock(gb: *GraphicsBase, rp: *RastPort, shown: *const Shown, left: i32, top: i32) void {
    const font = shown.font.?;
    const height = shown.height;
    graphics.SetFont(gb, rp, font);
    var baseline_of: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline_of) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    const baseline: i32 = @intCast(baseline_of);
    const row: i32 = @intCast(height + 2);

    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(255, 200, 80));
    gb.Move(rp, left, top + baseline);
    var label_len: u32 = 0;
    while (shown.label[label_len] != 0) label_len += 1;
    gb.Text(rp, &shown.label, label_len);

    set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(255, 255, 255));
    for (line_starts, 0..) |first, i| {
        const line = lineOf(first, false);
        gb.Move(rp, left, top + row * @as(i32, @intCast(i + 1)) + baseline);
        gb.Text(rp, &line, per_line);
    }
}

/// How many lines TIMES draws in each size: 64 of 32 characters.
const timed_lines = 64;

/// The E-clock now, and its rate into `rate`.
fn eclock(tb: *TimerBase, rate: *u32) u64 {
    var ev: timer.EClockVal = .{};
    rate.* = tb.ReadEClock(&ev);
    return ev.toTicks();
}

/// Draws `timed_lines` lines in `font` over the block at `top`, in JAM2,
/// and answers how many microseconds that took.
fn timeFont(gb: *GraphicsBase, tb: *TimerBase, rp: *RastPort, font: *graphics.TextFont, left: i32, top: i32) u32 {
    graphics.SetFont(gb, rp, font);
    set(gb, rp, graphics.RPTAG_DrMd, graphics.DRMD_JAM2);
    const line = lineOf(64, false);
    var rate: u32 = 0;
    const start = eclock(tb, &rate);
    for (0..timed_lines) |_| {
        gb.Move(rp, left, top);
        gb.Text(rp, &line, per_line);
    }
    const ticks = eclock(tb, &rate) - start;
    set(gb, rp, graphics.RPTAG_DrMd, graphics.DRMD_JAM1);
    if (rate == 0) return 0;
    return @intCast(ticks * 1_000_000 / rate);
}

/// "pospaz.font 8" or "pospaz.font 16" into `out`.
fn nameLine(out: *[48:0]u8, height: u32) void {
    const prefix = "pospaz.font ";
    for (prefix, 0..) |c, i| out[i] = c;
    var at: u32 = prefix.len;
    if (height >= 10) {
        out[at] = '0' + @as(u8, @intCast(height / 10));
        at += 1;
    }
    out[at] = '0' + @as(u8, @intCast(height % 10));
}

/// A size file read whole into memory of its own, or null with the reason
/// said. The block and its size go to `block` and `size`.
fn loadFile(sys: *ExecBase, dl: *DosBase, path: [*:0]const u8, size: *u32) ?[*]align(4) u8 {
    const fh = dl.Open(path, dos.MODE_OLDFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), path);
        return null;
    };
    defer _ = dl.Close(fh);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(fh, &fib)) {
        _ = dl.PrintFault(dl.IoErr(), path);
        return null;
    }
    const bytes: u32 = @intCast(fib.size);
    const block: [*]align(4) u8 = @ptrCast(@alignCast(sys.AllocVec(@max(bytes, 4), exec.MEMF_ANY) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, path);
        return null;
    }));
    if (dl.Read(fh, block, @intCast(bytes)) != bytes) {
        _ = dl.PrintFault(dl.IoErr(), path);
        sys.FreeVec(block);
        return null;
    }
    size.* = bytes;
    return block;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
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

    // The fonts to show: the file's, SIZE of the ROM's alone, or all the
    // ROM has.
    var shown: [rom_sizes.len]Shown = @splat(.{});
    var count: usize = 0;
    var loaded: ?[*]align(4) u8 = null;
    var file_font: graphics.TextFont = undefined;
    var file_added = false;
    var colour_file = false;
    defer if (loaded) |block| {
        if (file_added) _ = gb.RemFont(&file_font);
        sys.FreeVec(block);
    };
    defer for (shown[0..count]) |one| if (one.font) |f| gb.CloseFont(f);

    if (rdargs.string(argv[arg_file])) |path| {
        var size: u32 = 0;
        const block = loadFile(sys, dl, path, &size) orelse return dos.RETURN_FAIL;
        loaded = block;
        if (!fontimage.check(block, size) or !fontimage.sound(block, size)) {
            _ = Printf(dl, MSG_NOTFONT, .{path});
            return dos.RETURN_FAIL;
        }
        const image: *const fontimage.FontImage = @ptrCast(block);
        file_font = .{ .node = .{ .name = path }, .image = image, .flags = graphics.FPF_DISKFONT };
        if (!gb.AddFont(&file_font)) {
            _ = Printf(dl, MSG_NOADD, .{path});
            return dos.RETURN_FAIL;
        }
        file_added = true;
        colour_file = image.kind == .indexed8;
        shown[0].font = gb.OpenFont(&.{ .name = path, .y_size = image.height });
        shown[0].height = image.height;
        var i: usize = 0;
        while (path[i] != 0 and i < shown[0].label.len) : (i += 1) shown[0].label[i] = path[i];
        count = 1;
    } else if (argv[arg_size] != 0) {
        shown[0].height = @bitCast(@as(*const i32, @ptrFromInt(argv[arg_size])).*);
        count = 1;
    } else {
        for (rom_sizes, 0..) |size, i| shown[i].height = size;
        count = rom_sizes.len;
    }

    var inner_h: i32 = margin;
    var widest: u32 = 0;
    for (shown[0..count]) |*one| {
        if (one.font == null) {
            one.font = gb.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = @intCast(one.height) });
            nameLine(&one.label, one.height);
        }
        const font = one.font orelse {
            _ = Printf(dl, MSG_NOFONT, .{one.height});
            continue;
        };
        var extent: graphics.FontExtent = .{};
        gb.FontExtent(font, &extent);
        one.height = @intCast(extent.height);
        one.width = @intCast(extent.width);
        widest = @max(widest, one.width);
        inner_h += blockHeight(one.height) + gap;
    }
    if (inner_h == margin) return dos.RETURN_WARN;
    inner_h += margin - gap;
    const inner_w: i32 = @intCast(per_line * widest + 2 * margin);

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
    const left: i32 = @intCast(wattr(ib, w, wn.WA_BorderLeft));
    const top: i32 = @intCast(wattr(ib, w, wn.WA_BorderTop));
    const shown_w: i32 = @intCast(wattr(ib, w, wn.WA_InnerWidth));
    const shown_h: i32 = @intCast(wattr(ib, w, wn.WA_InnerHeight));

    // Black paper, but grey under a colour font: its colours may be dark,
    // a shadow for one, and would not show on black.
    const paper = if (colour_file) graphics.penRGB(160, 160, 160) else graphics.penRGB(0, 0, 0);
    set(gb, rp, graphics.RPTAG_APen, paper);
    gb.RectFill(rp, &.{ .min_x = left, .min_y = top, .max_x = left + shown_w - 1, .max_y = top + shown_h - 1 });
    set(gb, rp, graphics.RPTAG_DrMd, graphics.DRMD_JAM1);

    var y: i32 = top + margin;
    for (shown[0..count]) |*one| {
        if (one.font == null) continue;
        drawBlock(gb, rp, one, left + margin, y);
        y += blockHeight(one.height) + gap;
    }

    if (argv[arg_times] != 0) {
        var timer_req: timer.TimeRequest = .{};
        if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) == 0) {
            defer sys.CloseDevice(&timer_req.node);
            const tb: *TimerBase = @ptrCast(timer_req.node.device.?);
            var at: i32 = top + margin;
            for (shown[0..count]) |*one| {
                const font = one.font orelse continue;
                set(gb, rp, graphics.RPTAG_APen, graphics.penRGB(255, 255, 255));
                const us = timeFont(gb, tb, rp, font, left + margin, at + @as(i32, @intCast(one.height)));
                _ = Printf(dl, MSG_TIME, .{ @as([*:0]const u8, &one.label), @as(u32, timed_lines * per_line), us });
                at += blockHeight(one.height) + gap;
            }
        } else {
            _ = Printf(dl, MSG_NOTIMER, .{});
        }
    }

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
