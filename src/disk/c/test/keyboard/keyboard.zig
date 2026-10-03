// SPDX-License-Identifier: MIT
//! Keyboard: a field to type into, and the keyboard on the screen that
//! comes up for it. Built against the SDK only.
//!
//!   Keyboard MODE/K
//!
//! It sets when the on-screen keyboard comes up - MODE `ALWAYS` (the
//! default here, so a machine with keys shows it too), `AUTO` (on a board
//! with no keyboard) or `NEVER` - opens a window with a field and gives
//! the field the input. The keyboard comes up at the bottom of the screen;
//! what is typed on it goes into the field; Return ends the field, the
//! keyboard goes, and the text is printed. A press in the field starts
//! again. The setting is put back as it was when the window is closed or
//! on Ctrl-C.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = sdk.utility.TagItem;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const gc = intuition.gadgetclass;
const wn = intuition.windows;
const classusr = intuition.classusr;

pub const COMMAND_NAME = "Keyboard";
const VERSION_STRING = "\x00$VER: Keyboard 1.0 (2.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "MODE/K";
const arg_mode = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_BADMODE = "MODE is ALWAYS, AUTO or NEVER\n";
const MSG_NOWINDOW = "No window\n";
const MSG_HELLO = "Type on the keyboard; Return ends the field. The close gadget or Ctrl-C end it\n";
const MSG_TYPED = "Typed: %s\n";

fn same(a: [*:0]const u8, b: []const u8) bool {
    for (b, 0..) |c, i| {
        const d = a[i];
        if (d == 0 or (d | 0x20) != (c | 0x20)) return false;
    }
    return a[b.len] == 0;
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
    var mode: u32 = intuition.KEYBOARD_ALWAYS;
    if (rdargs.string(argv[arg_mode])) |given| {
        mode = if (same(given, "ALWAYS")) intuition.KEYBOARD_ALWAYS else if (same(given, "AUTO")) intuition.KEYBOARD_AUTO else if (same(given, "NEVER")) intuition.KEYBOARD_NEVER else {
            _ = Printf(dl, MSG_BADMODE, .{});
            return dos.RETURN_ERROR;
        };
    }

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    var was: u32 = intuition.KEYBOARD_AUTO;
    _ = ib.GetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_Keyboard, .data = @intFromPtr(&was) }, .{} });
    _ = ib.SetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_Keyboard, .data = mode }, .{} });
    defer _ = ib.SetPrefs(&[_]TagItem{ .{ .tag = intuition.IPREFS_Keyboard, .data = was }, .{} });

    var buffer: [80]u8 = @splat(0);
    const field = ib.NewObjectTagList(null, classusr.STRGCLASS, &[_]TagItem{
        .{ .tag = gc.GA_ID, .data = 1 },
        .{ .tag = gc.GA_Left, .data = 10 },
        .{ .tag = gc.GA_Top, .data = 30 },
        .{ .tag = gc.GA_RelWidth, .data = @bitCast(@as(isize, -20)) },
        .{ .tag = gc.GA_Height, .data = 16 },
        .{ .tag = gc.GA_RelVerify, .data = 1 },
        .{ .tag = gc.STRINGA_Buffer, .data = @intFromPtr(&buffer) },
        .{ .tag = gc.STRINGA_MaxChars, .data = buffer.len },
        .{},
    }) orelse return dos.RETURN_FAIL;
    defer ib.DisposeObject(field);
    const window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_Title, .data = @intFromPtr("Keyboard") },
        .{ .tag = wn.WA_Left, .data = 40 },
        .{ .tag = wn.WA_Top, .data = 40 },
        .{ .tag = wn.WA_Width, .data = 360 },
        .{ .tag = wn.WA_Height, .data = 70 },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_Gadgets, .data = @intFromPtr(field) },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_GADGETUP },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(window);
    _ = ib.ActivateGadget(field, window, null);
    _ = Printf(dl, MSG_HELLO, .{});

    while (true) {
        const got = ib.WaitIMsg(window, exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) return dos.RETURN_WARN;
        var closed = false;
        while (ib.GetIMsg(window)) |im| {
            if (im.class == wn.IDCMP_CLOSEWINDOW) closed = true;
            if (im.class == wn.IDCMP_GADGETUP) _ = Printf(dl, MSG_TYPED, .{@as([*:0]const u8, @ptrCast(&buffer))});
            ib.ReplyIMsg(im);
        }
        if (closed) return dos.RETURN_OK;
    }
}
