// SPDX-License-Identifier: MIT
//! Tap: a finger's tap, or a finger's drag, put into input.device as a
//! touch panel would, for a display with no touch panel to tap - QEMU's.
//! Built against the SDK only.
//!
//!   Tap X/N,Y/N,TOX/K/N,TOY/K/N,DEMO/S
//!
//! A finger comes down at X,Y and lifts there; with TOX and TOY it moves
//! to that place in steps, a fiftieth of a second apart, and lifts there.
//! DEMO instead opens a screen of its own, its bar uncovered, with a
//! window that has menus, and prints each pick and each move of the window
//! until the window is closed or a minute is up - something to tap at from
//! another shell.
//! Each step is the two events input.device makes for the pointer finger,
//! written one after the other (IND_WRITEEVENT takes one): an
//! IECLASS_TOUCH and an IECLASS_NEWPOINTERPOS marked IESUBCLASS_FINGER.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const mn = intuition.menus;
const wn = intuition.windows;
const sc = intuition.screens;
const TagItem = sdk.utility.TagItem;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const ie = sdk.devices.inputevent;
const input = sdk.devices.input;
const touch = sdk.devices.touch;
const InputEvent = ie.InputEvent;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Tap";
const VERSION_STRING = "\x00$VER: Tap 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "X/N,Y/N,TOX/K/N,TOY/K/N,DEMO/S";
const steps = 10;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    if (argv[4] != 0) return demo(sys, dl);
    const x = dos.rdargs.number(argv[0]) orelse return usage(dl);
    const y = dos.rdargs.number(argv[1]) orelse return usage(dl);
    const to_x = dos.rdargs.number(argv[2]) orelse x;
    const to_y = dos.rdargs.number(argv[3]) orelse y;

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{};
    io.req.message.reply_port = port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(input.INPUTNAME, 0, &io.req, 0) != 0) {
        _ = Printf(dl, "%s: no %s\n", .{ COMMAND_NAME, input.INPUTNAME });
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&io.req);

    finger(sys, &io, touch.TOUCH_DOWN, ie.IECODE_LBUTTON, ie.IEQUALIFIER_LEFTBUTTON, x, y);
    if (to_x != x or to_y != y) {
        var step: i32 = 1;
        while (step <= steps) : (step += 1) {
            _ = dl.Delay(1);
            finger(sys, &io, touch.TOUCH_MOVE, ie.IECODE_NOBUTTON, ie.IEQUALIFIER_LEFTBUTTON, x + @divTrunc((to_x - x) * step, steps), y + @divTrunc((to_y - y) * step, steps));
        }
    }
    _ = dl.Delay(1);
    finger(sys, &io, touch.TOUCH_UP, ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX, 0, to_x, to_y);
    return dos.RETURN_OK;
}

fn usage(dl: *DosBase) i32 {
    _ = Printf(dl, "%s: X and Y, or DEMO\n", .{COMMAND_NAME});
    return dos.RETURN_FAIL;
}

const demo_menus = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    .{ .type = mn.NM_ITEM, .label = "Open" },
    .{ .type = mn.NM_ITEM, .label = "Save" },
    .{ .type = mn.NM_ITEM, .label = "Quit" },
    .{ .type = mn.NM_TITLE, .label = "Edit" },
    .{ .type = mn.NM_ITEM, .label = "Cut" },
    .{ .type = mn.NM_ITEM, .label = "Copy" },
    .{ .type = mn.NM_END },
};

/// A screen with a window that has menus, each pick and move printed.
fn demo(sys: *ExecBase, dl: *DosBase) i32 {
    const lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const ib: *IntuitionBase = @ptrCast(lib);
    const screen = ib.OpenScreenTagList(&[_]TagItem{ .{ .tag = sc.SA_Title, .data = @intFromPtr("Tap - a screen to tap") }, .{} }) orelse return dos.RETURN_FAIL;
    defer _ = ib.CloseScreen(screen);
    const window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_CustomScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 200 },
        .{ .tag = wn.WA_Top, .data = 100 },
        .{ .tag = wn.WA_Width, .data = 320 },
        .{ .tag = wn.WA_Height, .data = 160 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Menus by a tap") },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_MENUPICK | wn.IDCMP_CHANGEWINDOW | wn.IDCMP_CLOSEWINDOW },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.CloseWindow(window);
    const strip = ib.CreateMenusA(&demo_menus, null) orelse return dos.RETURN_FAIL;
    defer ib.FreeMenus(strip);
    if (!ib.LayoutMenusA(strip, screen, null) or !ib.SetMenuStrip(window, strip)) return dos.RETURN_FAIL;
    defer ib.ClearMenuStrip(window);
    _ = Printf(dl, "tap the bar; a minute\n", .{});
    _ = dl.Flush(dl.Output());

    var ticks: u32 = 0;
    while (ticks < 60) : (ticks += 1) {
        _ = dl.Delay(50);
        while (ib.GetIMsg(window)) |message| {
            const class = message.class;
            const code = message.code;
            ib.ReplyIMsg(message);
            switch (class) {
                wn.IDCMP_CLOSEWINDOW => return dos.RETURN_OK,
                wn.IDCMP_MENUPICK => if (code == mn.MENUNULL) {
                    _ = Printf(dl, "nothing picked\n", .{});
                } else {
                    _ = Printf(dl, "picked menu %lu item %lu\n", .{ @as(u64, mn.MENUNUM(code)), @as(u64, mn.ITEMNUM(code)) });
                },
                wn.IDCMP_CHANGEWINDOW => {
                    var left: usize = 0;
                    var top: usize = 0;
                    ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = wn.WA_Left, .data = @intFromPtr(&left) }, .{ .tag = wn.WA_Top, .data = @intFromPtr(&top) }, .{} });
                    _ = Printf(dl, "window now at %lu,%lu\n", .{ @as(u64, left), @as(u64, top) });
                },
                else => {},
            }
            _ = dl.Flush(dl.Output());
        }
    }
    return dos.RETURN_OK;
}

/// One step of the finger: the touch, then the pointer.
fn finger(sys: *ExecBase, io: *exec.IOStdReq, kind: u32, code: u32, qualifier: u32, x: i32, y: i32) void {
    var events = [2]InputEvent{
        .{ .class = ie.IECLASS_TOUCH, .subclass = kind, .code = 0, .qualifier = qualifier, .x = x, .y = y },
        .{ .class = ie.IECLASS_NEWPOINTERPOS, .subclass = ie.IESUBCLASS_FINGER, .code = code, .qualifier = qualifier, .x = x, .y = y },
    };
    for (&events) |*event| {
        io.req.command = input.IND_WRITEEVENT;
        io.data = event;
        io.length = @sizeOf(InputEvent);
        _ = sys.DoIO(&io.req);
    }
}
