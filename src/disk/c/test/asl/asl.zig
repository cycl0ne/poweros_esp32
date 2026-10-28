// SPDX-License-Identifier: MIT
//! Asl: the file requester, asked for a name and told what it answered.
//! Built against the SDK only.
//!
//!   Asl DIR MULTI/S SAVE/S DRAWERS/S PATTERN/K FONT/S ASYNC/S ABORT/K/N
//!
//! It opens asl.library, makes a file requester starting in `DIR` -
//! `SYS:` unless another is named - and puts it up. What it was answered
//! with is printed: the drawer and the name, or with `MULTI` every name
//! picked. `SAVE` asks for a name to save under, `DRAWERS` for a drawer
//! rather than a file, and `PATTERN` gives the requester a Pattern field
//! starting on that pattern. `FONT` puts up the font requester instead,
//! with the styles, both pens and the drawing mode on it, and prints the
//! font it was answered with.
//!
//! `ASYNC` asks without waiting (`ASLFR_ReplyPort`): the requester runs on
//! a process of its own while this one prints a line every second, and
//! the answer comes as a message. `ABORT` takes it down after that many
//! seconds (`AbortAslRequest`), as Ctrl-C in the shell does at once.
//!
//! The requester is answered with its buttons, with a second press on a
//! line, or from the keyboard: the letter underlined in each label works
//! its gadget.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const asl = sdk.asl;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AslBase = sdk.interface.asl.AslBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Asl";
const VERSION_STRING = "\x00$VER: Asl 1.1 (28.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DIR,MULTI/S,SAVE/S,DRAWERS/S,PATTERN/K,FONT/S,ASYNC/S,ABORT/K/N";
const arg_dir = 0;
const arg_multi = 1;
const arg_save = 2;
const arg_drawers = 3;
const arg_pattern = 4;
const arg_font = 5;
const arg_async = 6;
const arg_abort = 7;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOREQUEST = "No requester\n";
const MSG_GAVEUP = "Nothing picked\n";
const MSG_ANSWER = "Drawer \"%s\", file \"%s\"\n";
const MSG_FONT = "Font \"%s\" %lu, style %lu, pens %lu and %lu, mode %lu\n";
const MSG_ONE = "  %s\n";
const MSG_COUNT = "%lu names picked:\n";
const MSG_NOPORT = "No port\n";
const MSG_WAITING = "Asking, %lu s\n";
const MSG_ABORTING = "Taking it down\n";

/// The font requester, with everything it can show turned on.
fn askFont(sys: *ExecBase, dl: *DosBase, ab: *AslBase) i32 {
    _ = sys;
    const handle = ab.AllocAslRequest(asl.ASL_FontRequest, &[_]TagItem{
        .{ .tag = asl.ASLFO_TitleText, .data = @intFromPtr("Pick a font") },
        .{ .tag = asl.ASLFO_DoStyle, .data = 1 },
        .{ .tag = asl.ASLFO_DoFrontPen, .data = 1 },
        .{ .tag = asl.ASLFO_DoBackPen, .data = 1 },
        .{ .tag = asl.ASLFO_DoDrawMode, .data = 1 },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOREQUEST, .{});
        return dos.RETURN_FAIL;
    };
    defer ab.FreeAslRequest(handle);
    const req: *asl.FontRequester = @ptrCast(@alignCast(handle));
    if (!ab.AslRequest(handle, null)) {
        _ = Printf(dl, MSG_GAVEUP, .{});
        return dos.RETURN_WARN;
    }
    _ = Printf(dl, MSG_FONT, .{
        req.attr.name,
        @as(u64, req.attr.y_size),
        @as(u64, req.attr.style),
        @as(u64, req.front_pen),
        @as(u64, req.back_pen),
        @as(u64, req.draw_mode),
    });
    return dos.RETURN_OK;
}

/// The requester put up on its own process, a line printed every second
/// until its message comes; taken down after `abort` seconds or at
/// Ctrl-C. Whether it was answered.
fn askAsync(sys: *ExecBase, dl: *DosBase, ab: *AslBase, handle: *anyopaque, port: *exec.MsgPort, abort: ?i32) bool {
    if (!ab.AslRequest(handle, &[_]TagItem{ .{ .tag = asl.ASLFR_ReplyPort, .data = @intFromPtr(port) }, .{} })) return false;
    var seconds: u32 = 0;
    var aborted = false;
    while (true) {
        if (sys.GetMsg(port)) |message| {
            const ended: *asl.AslMessage = @ptrCast(@alignCast(message));
            return ended.answered != 0;
        }
        const broken = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0;
        const due = if (abort) |after| after >= 0 and seconds >= @as(u32, @intCast(after)) else false;
        if (!aborted and (broken or due)) {
            _ = Printf(dl, MSG_ABORTING, .{});
            ab.AbortAslRequest(handle);
            aborted = true;
        }
        dl.Delay(50);
        seconds += 1;
        if (!aborted) _ = Printf(dl, MSG_WAITING, .{@as(u64, seconds)});
    }
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [8]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const dir = dos.rdargs.string(argv[arg_dir]) orelse "SYS:";
    const pattern = dos.rdargs.string(argv[arg_pattern]);

    const asl_lib = sys.OpenLibrary(asl.ASLNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{asl.ASLNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(asl_lib);
    const ab: *AslBase = @ptrCast(asl_lib);

    if (argv[arg_font] != 0) return askFont(sys, dl, ab);

    const ignore = sdk.utility.TAG_IGNORE;
    const handle = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
        .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr(@as([*:0]const u8, if (argv[arg_save] != 0) "Save as" else "Pick a file")) },
        .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr(dir) },
        .{ .tag = asl.ASLFR_DoMultiSelect, .data = @intFromBool(argv[arg_multi] != 0) },
        .{ .tag = asl.ASLFR_DoSaveMode, .data = @intFromBool(argv[arg_save] != 0) },
        .{ .tag = asl.ASLFR_DrawersOnly, .data = @intFromBool(argv[arg_drawers] != 0) },
        .{ .tag = if (pattern != null) asl.ASLFR_DoPatterns else ignore, .data = 1 },
        .{ .tag = if (pattern != null) asl.ASLFR_InitialPattern else ignore, .data = @intFromPtr(pattern) },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOREQUEST, .{});
        return dos.RETURN_FAIL;
    };
    defer ab.FreeAslRequest(handle);
    const req: *asl.FileRequester = @ptrCast(@alignCast(handle));

    const answered = if (argv[arg_async] != 0) blk: {
        const port = sys.CreateMsgPort() orelse {
            _ = Printf(dl, MSG_NOPORT, .{});
            return dos.RETURN_FAIL;
        };
        defer sys.DeleteMsgPort(port);
        break :blk askAsync(sys, dl, ab, handle, port, dos.rdargs.number(argv[arg_abort]));
    } else ab.AslRequest(handle, null);
    if (!answered) {
        _ = Printf(dl, MSG_GAVEUP, .{});
        return dos.RETURN_WARN;
    }
    _ = Printf(dl, MSG_ANSWER, .{ req.drawer orelse "", req.file orelse "" });
    if (req.num_args > 0) if (req.arg_list) |list| {
        _ = Printf(dl, MSG_COUNT, .{@as(u64, @intCast(req.num_args))});
        for (list[0..@intCast(req.num_args)]) |arg| {
            _ = Printf(dl, MSG_ONE, .{arg.name orelse ""});
        }
    };
    return dos.RETURN_OK;
}
