// SPDX-License-Identifier: MIT
//! Screens: a screen's buffers shown in turn, and a second screen in front
//! of the first. Built against the SDK only.
//!
//!   Screens FRAMES/N,SCREEN/S,SWITCH/S
//!
//! Without SCREEN it opens a screen of its own and double-buffers it: a box
//! bounces over a black picture drawn into one of the screen's two buffers
//! while the other is shown, and `ChangeScreenBuffer` shows each finished
//! one from the display's next frame - FRAMES of them (180 by default), or
//! until Ctrl-C. Then the screen goes behind and closes, and the frames a
//! second are printed: the display's own rate, since every flip waits for
//! a frame.
//!
//! With SCREEN it opens a second screen, shows it for two seconds in front
//! of the first, puts it behind, and closes it.
//!
//! With SWITCH it opens a second screen with a window on it, and a window
//! on the default screen, each with a button: "To back" puts the second
//! screen behind, "To front" brings it forward again, as often as wanted.
//! Either window's close gadget, or Ctrl-C, ends it.
//!
//! The screen and its second buffer each take a picture of the display's
//! memory: two more than the Workbench screen's.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const sc = intuition.screens;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;
const RastPort = graphics.RastPort;

pub const COMMAND_NAME = "Screens";
const VERSION_STRING = "\x00$VER: Screens 1.0 (25.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FRAMES/N,SCREEN/S,SWITCH/S";
const arg_frames = 0;
const arg_screen = 1;
const arg_switch = 2;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOBUFFER = "No room in the display's memory for another picture\n";
const MSG_FRAMES = "%lu frames in %lu ticks: %lu a second\n";
const MSG_REFUSED = "%lu flips waited for the menus\n";
const MSG_SECOND = "A second screen for two seconds\n";
const MSG_NOSECOND = "No second screen - error %lu\n";
const MSG_SWITCH = "Two screens: \"To back\" and \"To front\" switch them; a close gadget or Ctrl-C ends it\n";
const MSG_NOWINDOW = "No window\n";
const MSG_SWITCHED = "%lu switches\n";

const default_frames = 180;
const box = 48;

/// dos's ticks, 50 a second, since midnight.
fn ticksNow(dl: *DosBase) u64 {
    var now: dos.DateStamp = .{};
    _ = dl.DateStamp(&now);
    return @as(u64, @intCast(now.minute)) * 60 * 50 + @as(u64, @intCast(now.tick));
}

fn pen(gb: *GraphicsBase, rp: *RastPort, value: graphics.Pen) void {
    const tags = [_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = value }, .{} };
    gb.SetRPAttrs(rp, &tags);
}

fn attr(ib: *IntuitionBase, screen: *intuition.Screen, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    const ask = [_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} };
    ib.GetScreenAttrs(screen, &ask);
    return value;
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
    const frames: u32 = if (argv[arg_frames] != 0) @bitCast(@as(*const i32, @ptrFromInt(argv[arg_frames])).*) else default_frames;

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

    if (argv[arg_switch] != 0) return switchScreens(dl, ib);
    if (argv[arg_screen] != 0) return secondScreen(dl, ib, gb);
    return doubleBuffer(dl, ib, gb, frames);
}

/// A box bouncing on a screen of its own, drawn into one of its two
/// buffers while the other is shown.
fn doubleBuffer(dl: *DosBase, ib: *IntuitionBase, gb: *GraphicsBase, frames: u32) i32 {
    var why: u32 = 0;
    const screen = ib.OpenScreenTagList(&[_]TagItem{
        .{ .tag = sc.SA_Quiet, .data = 1 },
        .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOSECOND, .{@as(u64, why)});
        return dos.RETURN_WARN;
    };
    defer _ = ib.CloseScreen(screen);
    // Put behind before it closes, so the display goes straight back to
    // the screen that was in front.
    defer ib.ScreenToBack(screen);
    const width: i32 = @intCast(attr(ib, screen, sc.SA_Width));
    const height: i32 = @intCast(attr(ib, screen, sc.SA_Height));

    const own = ib.AllocScreenBuffer(screen, sc.SB_SCREEN_BITMAP) orelse {
        _ = Printf(dl, MSG_NOBUFFER, .{});
        return dos.RETURN_WARN;
    };
    defer ib.FreeScreenBuffer(screen, own);
    const second = ib.AllocScreenBuffer(screen, 0) orelse {
        _ = Printf(dl, MSG_NOBUFFER, .{});
        return dos.RETURN_WARN;
    };
    defer ib.FreeScreenBuffer(screen, second);
    const buffers = [2]*sc.ScreenBuffer{ own, second };

    var x: i32 = 0;
    var y: i32 = 0;
    var dx: i32 = 6;
    var dy: i32 = 4;
    var drawing: usize = 1;
    var shown: u32 = 0;
    var refused: u32 = 0;
    const began = ticksNow(dl);
    while (shown < frames and dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        const rp = buffers[drawing].rast_port;
        pen(gb, rp, graphics.penRGB(0, 0, 0));
        gb.RectFill(rp, &.{ .max_x = width, .max_y = height });
        pen(gb, rp, graphics.penRGB(0xFF, 0xAA, 0x00));
        gb.RectFill(rp, &.{ .min_x = x, .min_y = y, .max_x = x + box, .max_y = y + box });
        if (!ib.ChangeScreenBuffer(screen, buffers[drawing])) {
            refused += 1;
            dl.Delay(1);
            continue;
        }
        drawing ^= 1;
        shown += 1;
        x += dx;
        y += dy;
        if (x < 0 or x + box > width) dx = -dx;
        if (y < 0 or y + box > height) dy = -dy;
    }
    const ticks = ticksNow(dl) - began;
    _ = Printf(dl, MSG_FRAMES, .{ @as(u64, shown), ticks, if (ticks == 0) @as(u64, 0) else @as(u64, shown) * 50 / ticks });
    if (refused != 0) _ = Printf(dl, MSG_REFUSED, .{@as(u64, refused)});
    return dos.RETURN_OK;
}

/// A second screen, in front of the first for two seconds.
fn secondScreen(dl: *DosBase, ib: *IntuitionBase, gb: *GraphicsBase) i32 {
    var why: u32 = 0;
    const screen = ib.OpenScreenTagList(&[_]TagItem{
        .{ .tag = sc.SA_Title, .data = @intFromPtr("A second screen") },
        .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOSECOND, .{@as(u64, why)});
        return dos.RETURN_WARN;
    };
    _ = Printf(dl, MSG_SECOND, .{});
    const rp: *RastPort = @ptrFromInt(attr(ib, screen, sc.SA_RastPort));
    const top: i32 = @intCast(attr(ib, screen, sc.SA_BarHeight));
    pen(gb, rp, graphics.penRGB(0x00, 0x66, 0xAA));
    gb.RectFill(rp, &.{ .min_x = 40, .min_y = top + 40, .max_x = 240, .max_y = top + 140 });
    dl.Delay(100);
    ib.ScreenToBack(screen);
    _ = ib.CloseScreen(screen);
    return dos.RETURN_OK;
}

const button_to_back = 1;
const button_to_front = 2;

/// A button with words on it, the size of a finger.
fn button(ib: *IntuitionBase, id: usize, text: [*:0]const u8) ?*intuition.Object {
    const gc = intuition.gadgetclass;
    return ib.NewObjectTagList(null, intuition.classusr.BUTTONGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_Left, .data = 20 },
        .{ .tag = gc.GA_Top, .data = 40 },
        .{ .tag = gc.GA_Width, .data = 140 },
        .{ .tag = gc.GA_Height, .data = 40 },
        .{ .tag = gc.GA_Text, .data = @intFromPtr(text) },
        .{ .tag = gc.GA_ID, .data = id },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{},
    });
}

const window_width = 180;
const window_height = 100;

/// A window with one button on a screen, `at_right` near the screen's right
/// edge and otherwise near its left, whatever size the display is.
fn buttonWindow(ib: *IntuitionBase, screen: *intuition.Screen, title: [*:0]const u8, at_right: bool, gadget: *intuition.Object) ?*intuition.Window {
    const wn = intuition.windows;
    const width = attr(ib, screen, sc.SA_Width);
    const margin = 20;
    const left: usize = if (at_right and width > window_width + margin) width - window_width - margin else margin;
    const top: usize = attr(ib, screen, sc.SA_BarHeight) + margin;
    return ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_CustomScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = left },
        .{ .tag = wn.WA_Top, .data = top },
        .{ .tag = wn.WA_Width, .data = window_width },
        .{ .tag = wn.WA_Height, .data = window_height },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(title) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(gadget) },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_GADGETUP | wn.IDCMP_CLOSEWINDOW },
        .{},
    });
}

/// What a window's messages asked for: the button pressed, or to stop.
const Asked = struct { button: usize = 0, close: bool = false };

fn drain(ib: *IntuitionBase, w: *intuition.Window) Asked {
    const wn = intuition.windows;
    var asked: Asked = .{};
    while (ib.GetIMsg(w)) |im| {
        const class = im.class;
        const gadget: ?*intuition.Object = @ptrCast(im.iaddress);
        ib.ReplyIMsg(im);
        if (class == wn.IDCMP_CLOSEWINDOW) asked.close = true;
        if (class == wn.IDCMP_GADGETUP) {
            var id: usize = 0;
            _ = ib.GetAttr(intuition.gadgetclass.GA_ID, gadget, &id);
            asked.button = id;
        }
    }
    return asked;
}

/// Two screens and a button on each to switch between them.
fn switchScreens(dl: *DosBase, ib: *IntuitionBase) i32 {
    const home = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_WARN;
    };
    defer ib.UnlockPubScreen(null, home);
    var why: u32 = 0;
    const second = ib.OpenScreenTagList(&[_]TagItem{
        .{ .tag = sc.SA_Title, .data = @intFromPtr("Screens - the second screen") },
        .{ .tag = sc.SA_ErrorCode, .data = @intFromPtr(&why) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOSECOND, .{@as(u64, why)});
        return dos.RETURN_WARN;
    };
    defer _ = ib.CloseScreen(second);
    // Behind before it closes, so the display goes straight back.
    defer ib.ScreenToBack(second);

    const to_back = button(ib, button_to_back, "To back") orelse return noWindow(dl);
    defer ib.DisposeObject(to_back);
    const to_front = button(ib, button_to_front, "To front") orelse return noWindow(dl);
    defer ib.DisposeObject(to_front);
    // Closed before their buttons are disposed: the defers run backwards.
    const there = buttonWindow(ib, second, "Second screen", false, to_back) orelse return noWindow(dl);
    defer ib.CloseWindow(there);
    const here = buttonWindow(ib, home, "Screens", true, to_front) orelse return noWindow(dl);
    defer ib.CloseWindow(here);
    // The second screen's window takes the input, since its screen is the
    // one in front.
    ib.ActivateWindow(there);

    _ = Printf(dl, MSG_SWITCH, .{});
    var switches: u32 = 0;
    while (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        const on_second = drain(ib, there);
        const on_home = drain(ib, here);
        if (on_second.close or on_home.close) break;
        if (on_second.button == button_to_back) {
            ib.ScreenToBack(second);
            ib.ActivateWindow(here);
            switches += 1;
        }
        if (on_home.button == button_to_front) {
            ib.ScreenToFront(second);
            ib.ActivateWindow(there);
            switches += 1;
        }
        dl.Delay(2);
    }
    _ = Printf(dl, MSG_SWITCHED, .{@as(u64, switches)});
    return dos.RETURN_OK;
}

fn noWindow(dl: *DosBase) i32 {
    _ = Printf(dl, MSG_NOWINDOW, .{});
    return dos.RETURN_FAIL;
}
