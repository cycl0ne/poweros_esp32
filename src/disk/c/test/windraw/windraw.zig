// SPDX-License-Identifier: MIT
//! WinDraw: how long a drawing in a window takes, each call on its own -
//! as a program draws that does not hold its window's layer. Built
//! against the SDK only.
//!
//!   WinDraw ROUNDS/K/N,COVER/S
//!
//! It opens a window on the default public screen and draws into it
//! ROUNDS times (2000 if not given) each of: a small RectFill, a line of
//! text, a RectFill over the whole inside, and a slanted line; then it
//! prints the time one call took. Every call is handed on to the display
//! by itself, so on a screen whose windows are composed this is what
//! copying a drawing out of a window and handing it on to the board
//! costs. COVER opens a second window over the middle of the first
//! beforehand, so the first is seen in more pieces.

const sdk = @import("sdk");
const dos = sdk.dos;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TimerBase = timer.TimerBase;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const Rect = graphics.Rect;
const RastPort = graphics.RastPort;

pub const COMMAND_NAME = "WinDraw";
const VERSION_STRING = "\x00$VER: WinDraw 1.0 (25.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "ROUNDS/K/N,COVER/S";
const arg_rounds = 0;
const arg_cover = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display, or it shows another screen\n";
const MSG_NOWINDOW = "No window - the screen would not open one that size\n";
const MSG_TIME = "%-28s %5lu.%03lu us\n";

const inside_width = 600;
const inside_height = 400;
const words = "The quick brown fox jumps";

const Case = enum { small, text, whole, line };

const names = [_][*:0]const u8{
    "RectFill 32x32",
    "Text, 25 letters",
    "RectFill 600x400",
    "Draw, 300 slanted",
};

/// The window's inside, and what draws there.
const Bench = struct {
    gb: *GraphicsBase,
    rp: *RastPort,
    left: i32,
    top: i32,
    baseline: i32,

    fn pen(b: *Bench, round: u32) void {
        const colour = graphics.penRGB(@truncate(round *% 37), @truncate(round *% 91), @truncate(round *% 53));
        const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = colour }, .{} };
        b.gb.SetRPAttrs(b.rp, &tags);
    }

    fn draw(b: *Bench, case: Case, round: u32) void {
        b.pen(round);
        // Somewhere new inside each round, in steps that do not repeat soon.
        const x = b.left + @as(i32, @intCast(round * 53 % (inside_width - 300)));
        const y = b.top + @as(i32, @intCast(round * 29 % (inside_height - 40)));
        switch (case) {
            .small => b.gb.RectFill(b.rp, &.{ .min_x = x, .min_y = y, .max_x = x + 32, .max_y = y + 32 }),
            .text => {
                b.gb.Move(b.rp, x, y + b.baseline);
                b.gb.Text(b.rp, words, words.len);
            },
            .whole => b.gb.RectFill(b.rp, &.{ .min_x = b.left, .min_y = b.top, .max_x = b.left + inside_width, .max_y = b.top + inside_height }),
            .line => {
                b.gb.Move(b.rp, x, y);
                b.gb.Draw(b.rp, x + 300, y + 40);
            },
        }
    }
};

fn now(tb: *TimerBase) u64 {
    var ev: timer.EClockVal = .{};
    const rate = tb.ReadEClock(&ev);
    return ev.toTicks() * 1_000_000 / rate;
}

fn wattr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetWindowAttrs(w, &ask);
    return value;
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
    const rounds: u32 = if (argv[arg_rounds] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[arg_rounds])).*)) else 2000;

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

    var timer_req: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &timer_req.node, 0) != 0) {
        _ = Printf(dl, MSG_NOLIBRARY, .{sdk.interface.timer.NAME});
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&timer_req.node);
    const tb: *TimerBase = @ptrCast(timer_req.node.device.?);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_WARN;
    };
    defer ib.UnlockPubScreen(null, screen);

    const window_tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 60 },
        .{ .tag = wn.WA_Top, .data = 60 },
        .{ .tag = wn.WA_InnerWidth, .data = inside_width },
        .{ .tag = wn.WA_InnerHeight, .data = inside_height },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("WinDraw") },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    };
    const w = ib.OpenWindowTagList(&window_tags) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(w);

    // Over the middle of the first, leaving it a frame of four pieces.
    var cover: ?*intuition.Window = null;
    if (argv[arg_cover] != 0) {
        const cover_tags = [_]TagItem{
            .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
            .{ .tag = wn.WA_Left, .data = 60 + inside_width / 3 },
            .{ .tag = wn.WA_Top, .data = 60 + inside_height / 3 },
            .{ .tag = wn.WA_InnerWidth, .data = inside_width / 3 },
            .{ .tag = wn.WA_InnerHeight, .data = inside_height / 3 },
            .{ .tag = wn.WA_Title, .data = @intFromPtr("Cover") },
            .{},
        };
        cover = ib.OpenWindowTagList(&cover_tags);
    }
    defer if (cover) |c| ib.CloseWindow(c);

    const rp: *RastPort = @ptrFromInt(wattr(ib, w, wn.WA_RastPort));
    var font_baseline: u32 = 0;
    const ask = [_]TagItem{ .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&font_baseline) }, .{} };
    gb.GetRPAttrs(rp, &ask);
    var b = Bench{
        .gb = gb,
        .rp = rp,
        .left = @intCast(wattr(ib, w, wn.WA_BorderLeft)),
        .top = @intCast(wattr(ib, w, wn.WA_BorderTop)),
        .baseline = @intCast(font_baseline),
    };

    for ([_]Case{ .small, .text, .whole, .line }) |case| {
        const start = now(tb);
        var round: u32 = 0;
        while (round < rounds) : (round += 1) b.draw(case, round);
        const ns = (now(tb) - start) * 1000 / rounds;
        _ = Printf(dl, MSG_TIME, .{ names[@intFromEnum(case)], ns / 1000, ns % 1000 });
    }
    return dos.RETURN_OK;
}
