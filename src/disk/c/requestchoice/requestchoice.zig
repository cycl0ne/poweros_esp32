// SPDX-License-Identifier: MIT
//! RequestChoice: the shell asks a question with buttons, and is told
//! which was pressed. Built against the SDK only.
//!
//!   RequestChoice TITLE/A,BODY/A,GADGETS/M,PUBSCREEN/K
//!
//! It puts up a requester with `BODY` in it and a button for each word of
//! `GADGETS`, and writes the number of the one pressed: 1 for the first,
//! 2 for the second, and 0 for the last, which is the one that gives up -
//! the close gadget and Esc answer 0 as well. Without `GADGETS` it puts
//! up one button, `Ok`, which answers 0.
//!
//! The body and the buttons are taken as words, not as a format: a `%` in
//! either stands for itself.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = intuition.windows;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "RequestChoice";
const VERSION_STRING = "\x00$VER: RequestChoice 1.0 (28.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TITLE/A,BODY/A,GADGETS/M,PUBSCREEN/K";
const arg_title = 0;
const arg_body = 1;
const arg_gadgets = 2;
const arg_pubscreen = 3;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOWINDOW = "No screen to ask on\n";
const MSG_TOOLONG = "The question does not fit\n";
const MSG_ANSWER = "%ld\n";

/// How much of a question this command holds: the body and every button,
/// each with room for its doubled `%`s.
const text_max = 1024;

/// `text` copied into `into` at `at` with every `%` doubled, so that what
/// the user wrote is shown and not read as a format. The new `at`, or
/// null when it will not fit.
fn escaped(into: []u8, at: usize, text: [*:0]const u8) ?usize {
    var out = at;
    var i: usize = 0;
    while (text[i] != 0) : (i += 1) {
        if (out + 2 >= into.len) return null;
        into[out] = text[i];
        out += 1;
        if (text[i] == '%') {
            into[out] = '%';
            out += 1;
        }
    }
    return out;
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

    const int_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(int_lib);
    const ib: *IntuitionBase = @ptrCast(int_lib);

    // The body, then the buttons after it, each ended by its own NUL.
    var text: [text_max]u8 = @splat(0);
    const body_end = escaped(&text, 0, dos.rdargs.string(argv[arg_body]).?) orelse {
        _ = Printf(dl, MSG_TOOLONG, .{});
        return dos.RETURN_FAIL;
    };
    text[body_end] = 0;
    var at = body_end + 1;
    const buttons_at = at;
    const gadgets = dos.rdargs.multi(argv[arg_gadgets]);
    if (gadgets.len == 0) {
        const only = "Ok";
        @memcpy(text[at..][0..only.len], only);
        at += only.len;
    } else {
        for (gadgets, 0..) |gadget, i| {
            if (i > 0) {
                if (at + 1 >= text.len) {
                    _ = Printf(dl, MSG_TOOLONG, .{});
                    return dos.RETURN_FAIL;
                }
                text[at] = '|';
                at += 1;
            }
            at = escaped(&text, at, gadget) orelse {
                _ = Printf(dl, MSG_TOOLONG, .{});
                return dos.RETURN_FAIL;
            };
        }
    }
    text[at] = 0;

    // A window of nothing on the screen the requester is to appear on:
    // a requester belongs to a window, and this command has none of its
    // own.
    const screen = dos.rdargs.string(argv[arg_pubscreen]);
    const ignore = sdk.utility.TAG_IGNORE;
    const window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = if (screen != null) wn.WA_PubScreenName else ignore, .data = argv[arg_pubscreen] },
        .{ .tag = wn.WA_Left, .data = 0 },
        .{ .tag = wn.WA_Top, .data = 0 },
        .{ .tag = wn.WA_Width, .data = 16 },
        .{ .tag = wn.WA_Height, .data = 16 },
        .{ .tag = wn.WA_Borderless, .data = 1 },
        .{ .tag = wn.WA_Backdrop, .data = 1 },
        .{ .tag = wn.WA_NoCareRefresh, .data = 1 },
        .{ .tag = wn.WA_RMBTrap, .data = 1 },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(window);

    const easy = intuition.EasyStruct{
        .title = dos.rdargs.string(argv[arg_title]),
        .text_format = @ptrCast(&text),
        .gadget_format = @ptrCast(text[buttons_at..].ptr),
    };
    const pressed = ib.EasyRequestArgs(window, &easy, null, null);
    _ = Printf(dl, MSG_ANSWER, .{@as(i64, pressed)});
    return dos.RETURN_OK;
}
