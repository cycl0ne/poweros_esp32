// SPDX-License-Identifier: MIT
//! Pointer: windows with pointers of their own. Built against the SDK
//! only.
//!
//!   Pointer DELAY/S,HIDE/S
//!
//! It opens two windows on the default public screen. The first has a
//! crosshair of its own, a pointerclass object made from a picture in this
//! program, and the pointer is that crosshair whenever the first window is
//! the active one. The second has the default pointer; a click inside it
//! puts up the busy pointer for two seconds and takes it down again - with
//! DELAY through `WA_PointerDelay`, so it appears three tenths of a second
//! late. Each click first puts the busy pointer up with the delay and
//! takes it down at once, which never shows. With HIDE the first window
//! has no pointer at all (`WA_HidePointer`) in place of the crosshair, and
//! its clicks are still heard: each one is printed with where it was.
//! Either close gadget or Ctrl-C ends it.
//!
//! The pointer is seen once the mouse has moved: on a panel touched with a
//! finger there is none to see.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rtg = sdk.rtg;
const intuition = sdk.intuition;
const wn = intuition.windows;
const pc = intuition.pointerclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Pointer";
const VERSION_STRING = "\x00$VER: Pointer 1.1 (25.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DELAY/S,HIDE/S";
const arg_delay = 0;
const arg_hide = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOPOINTER = "No pointer object\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "The left window has a crosshair; click in the right one for the busy pointer. A close gadget or Ctrl-C ends it\n";
const MSG_BUSY = "Busy for two seconds%s\n";
const MSG_DELAYED = ", after a delay";
const MSG_HIDDEN = "The left window hides the pointer; clicks in it are still heard\n";
const MSG_CLICK = "Click at %ld,%ld with no pointer\n";

/// A crosshair 15 pixels each way, black lines edged in white, its point
/// in the middle - rgba32, the alpha 0 where the picture shows through.
const side = 15;
const crosshair: [side * side]u32 = blk: {
    var pixels: [side * side]u32 = @splat(0);
    const middle = side / 2;
    for (0..side) |i| {
        for ([_]usize{ middle - 1, middle + 1 }) |edge| {
            pixels[edge * side + i] = 0xFFFFFFFF;
            pixels[i * side + edge] = 0xFFFFFFFF;
        }
    }
    for (0..side) |i| {
        pixels[middle * side + i] = 0x000000FF;
        pixels[i * side + middle] = 0x000000FF;
    }
    break :blk pixels;
};

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
    const delay = argv[arg_delay] != 0;
    const hide = argv[arg_hide] != 0;

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    const picture = rtg.Surface{
        .pixels = @ptrCast(@constCast(&crosshair)),
        .width = side,
        .height = side,
        .pitch = side * 4,
        .size_bytes = side * side * 4,
        .format = .rgba32,
    };
    const cross = ib.NewObjectTagList(null, pc.POINTERCLASS, &[_]TagItem{
        .{ .tag = pc.POINTERA_BitMap, .data = @intFromPtr(&picture) },
        .{ .tag = pc.POINTERA_XOffset, .data = @bitCast(@as(isize, -(side / 2))) },
        .{ .tag = pc.POINTERA_YOffset, .data = @bitCast(@as(isize, -(side / 2))) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOPOINTER, .{});
        return dos.RETURN_FAIL;
    };
    // Disposed of after the windows close: the defers run backwards.
    defer ib.DisposeObject(cross);

    const idcmp = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_MOUSEBUTTONS;
    const crossed = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 40 },
        .{ .tag = wn.WA_Top, .data = 60 },
        .{ .tag = wn.WA_Width, .data = 260 },
        .{ .tag = wn.WA_Height, .data = 160 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Pointer: a crosshair") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = idcmp },
        .{ .tag = wn.WA_Pointer, .data = @intFromPtr(cross) },
        .{ .tag = wn.WA_HidePointer, .data = @intFromBool(hide) },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(crossed);
    const plain = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Left, .data = 320 },
        .{ .tag = wn.WA_Top, .data = 60 },
        .{ .tag = wn.WA_Width, .data = 260 },
        .{ .tag = wn.WA_Height, .data = 160 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Pointer: click for busy") },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = idcmp },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(plain);

    if (hide) {
        _ = Printf(dl, MSG_HIDDEN, .{});
    } else {
        _ = Printf(dl, MSG_HELLO, .{});
    }
    const busy_now = [_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 1 }, .{} };
    const busy_later = [_]TagItem{ .{ .tag = wn.WA_BusyPointer, .data = 1 }, .{ .tag = wn.WA_PointerDelay, .data = 1 }, .{} };
    while (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) {
        const on_first = drain(ib, crossed);
        if (on_first.close) break;
        if (hide and on_first.clicked) _ = Printf(dl, MSG_CLICK, .{ @as(i64, on_first.x), @as(i64, on_first.y) });
        const asked = drain(ib, plain);
        if (asked.close) break;
        if (asked.clicked) {
            // Busy for no time at all, with the delay: never seen.
            ib.SetWindowPointerA(plain, &busy_later);
            ib.SetWindowPointerA(plain, null);
            _ = Printf(dl, MSG_BUSY, .{if (delay) MSG_DELAYED else ""});
            ib.SetWindowPointerA(plain, if (delay) &busy_later else &busy_now);
            dl.Delay(100);
            ib.SetWindowPointerA(plain, null);
            // What was clicked while busy is not a new click.
            _ = drain(ib, plain);
        }
        dl.Delay(2);
    }
    return dos.RETURN_OK;
}

const Asked = struct { close: bool = false, clicked: bool = false, x: i32 = 0, y: i32 = 0 };

fn drain(ib: *IntuitionBase, w: *intuition.Window) Asked {
    var asked: Asked = .{};
    while (ib.GetIMsg(w)) |im| {
        const class = im.class;
        const code = im.code;
        const x = im.mouse_x;
        const y = im.mouse_y;
        ib.ReplyIMsg(im);
        if (class == wn.IDCMP_CLOSEWINDOW) asked.close = true;
        if (class == wn.IDCMP_MOUSEBUTTONS and code == wn.SELECTDOWN) {
            asked.clicked = true;
            asked.x = x;
            asked.y = y;
        }
    }
    return asked;
}
