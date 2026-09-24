// SPDX-License-Identifier: MIT
//! Console: a terminal in a window. Built against the SDK only.
//!
//!   Console TITLE/K,SCROLL/S,ALT/S,ROWS/K/N,COLS/K/N,SHELL/S,
//!           MOUSE/S,SNIP/S,NUL/S,STOP/S
//!
//! Opens a window on the default public screen, opens console.device on it,
//! and shows what the terminal can do - colours, styles, box drawing, a
//! scrolling region - then echoes what is typed into the window until its
//! close gadget is used or Ctrl-C reaches the command. What is typed comes
//! from the console's own read, which is keymap.library's work: cursor keys
//! and function keys arrive as their sequences and are printed by name.
//!
//! `MOUSE` gives the pointer to the program instead of to the selection -
//! presses, releases and drags arrive in the read stream and are printed
//! in the window as words - with Shift still selecting text, as every
//! terminal has it. `SNIP` installs a snip hook, which is how a clipboard
//! program would be told that a selection is finished. `NUL` writes a
//! string whose length is -1 rather than counted. `STOP` stops the unit
//! for three seconds: reads queue while it is stopped and are answered
//! when it starts again.
//!
//! `SHELL` does the other half of it: instead of driving the console
//! itself, it opens the window and hands it to the console handler by name
//! - `CON://///WINDOW 0x...` - and asks dos for a shell on it. The window
//! belongs to the console from that moment, which is why this does not
//! close it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const con = sdk.console;
const wn = intuition.windows;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Console";
const VERSION_STRING = "\x00$VER: Console 1.0 (20.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TITLE/K,SCROLL/S,ALT/S,ROWS/K/N,COLS/K/N,SHELL/S,MOUSE/S,SNIP/S,NUL/S,STOP/S";
const arg_title = 0;
const arg_scroll = 1;
const arg_alt = 2;
const arg_rows = 3;
const arg_cols = 4;
const arg_shell = 5;
const arg_mouse = 6;
const arg_snip = 7;
const arg_nul = 8;
const arg_stop = 9;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No screen to open a window on\n";
const MSG_NOWINDOW = "No window\n";
const MSG_NODEVICE = "No %s - is there a window for it?\n";
const MSG_OPEN = "Console    a window with a terminal in it - its close gadget or Ctrl-C ends it\n";
const MSG_SHELL = "Console    a shell in this window, through %s\n";
const MSG_NOSHELL = "Console    no shell in this window\n";
const MSG_SHELL_DONE = "Console    the shell ended (%d), and the console closed the window\n";
const MSG_DONE = "Console    closed after %d characters typed\n";
const MSG_SNIPPED = "Console    snip hook: %ld bytes, \"%s\"\n";
const MSG_STOPPED = "Console    stopped: type now, and nothing is read until it starts again\n";
const MSG_STARTED = "Console    started\n";

/// What is written into the window when it opens.
const demo =
    "\x1b[2J\x1b[H\x1b[1mPowerOS console\x1b[m - a VT terminal in a window\r\n\r\n" ++
    "  \x1b[30;47m 30 \x1b[31m 31 \x1b[32m 32 \x1b[33m 33 \x1b[34m 34 \x1b[35m 35 \x1b[36m 36 \x1b[m\r\n" ++
    "  \x1b[90;47m 90 \x1b[91m 91 \x1b[92m 92 \x1b[93m 93 \x1b[94m 94 \x1b[95m 95 \x1b[96m 96 \x1b[m\r\n" ++
    "  \x1b[38;5;208m38;5;208\x1b[m  \x1b[1mbold\x1b[m  \x1b[3mitalic\x1b[m  \x1b[4munderline\x1b[m  \x1b[7mreverse\x1b[m\r\n\r\n" ++
    "  \x1b(0lqqqqqqqqqqqqqqqwqqqqqqqqqqqqqqk\x1b(B\r\n" ++
    "  \x1b(0x\x1b(B line drawing  \x1b(0x\x1b(B ESC ( 0      \x1b(0x\x1b(B\r\n" ++
    "  \x1b(0tqqqqqqqqqqqqqqqnqqqqqqqqqqqqqqu\x1b(B\r\n" ++
    "  \x1b(0x\x1b(B cursor keys   \x1b(0x\x1b(B and the rest \x1b(0x\x1b(B\r\n" ++
    "  \x1b(0mqqqqqqqqqqqqqqqvqqqqqqqqqqqqqqj\x1b(B\r\n\r\n" ++
    "Drag over the text to select it, Shift+Insert or right-Amiga V to paste\r\n" ++
    "it back. Type; what you type is echoed here.\r\n";

fn write(sys: *ExecBase, io: *exec.IOStdReq, text: []const u8) void {
    io.req.command = exec.CMD_WRITE;
    io.data = @constCast(text.ptr);
    io.length = text.len;
    _ = sys.DoIO(&io.req);
}

/// A number into `buf`, as decimal digits. How many.
fn digits(buf: []u8, value: u32) usize {
    if (value >= 10) {
        const n = digits(buf, value / 10);
        buf[n] = '0' + @as(u8, @intCast(value % 10));
        return n + 1;
    }
    buf[0] = '0' + @as(u8, @intCast(value));
    return 1;
}

/// "line <n>", with the newline: one line of the scrolling stream.
fn numbered(buf: []u8, value: u32) usize {
    const head = "line ";
    for (head, 0..) |c, i| buf[i] = c;
    var n = head.len + digits(buf[head.len..], value);
    buf[n] = '\r';
    buf[n + 1] = '\n';
    n += 2;
    return n;
}

/// "CON://///WINDOW 0x...", the name a console on `window` is opened by.
/// How long it is.
fn consoleName(buf: []u8, window: usize) usize {
    const head = "CON://///WINDOW 0x";
    for (head, 0..) |c, i| buf[i] = c;
    var n = head.len;
    var shift: u5 = 28;
    var seen = false;
    while (true) : (shift -= 4) {
        const nibble: u8 = @intCast((window >> shift) & 0xF);
        if (nibble != 0 or seen or shift == 0) {
            seen = true;
            buf[n] = if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
            n += 1;
        }
        if (shift == 0) break;
    }
    buf[n] = 0;
    return n;
}

/// `CSI 8 ; rows ; cols t`, which asks for a window of that many cells.
fn sizeRequest(buf: []u8, rows: u32, cols: u32) usize {
    buf[0] = 0x1B;
    buf[1] = '[';
    buf[2] = '8';
    buf[3] = ';';
    var n: usize = 4 + digits(buf[4..], rows);
    buf[n] = ';';
    n += 1;
    n += digits(buf[n..], cols);
    buf[n] = 't';
    return n + 1;
}

/// The snip hook: console.device calls this on its own task whenever a
/// selection in a console window is finished. It may not wait, so it does
/// the least it can - counts the text and remembers it - and the program
/// prints it from its own loop.
const Snipped = struct {
    len: u32 = 0,
    text: [128:0]u8 = @splat(0),
    fresh: u8 = 0,
    /// Who to wake: the hook runs on the console's task, so it may not
    /// print - it writes the text down and signals the program, which is
    /// waiting for its console's reads anyway.
    sys: ?*ExecBase = null,
    task: ?*exec.Task = null,
    signal: u32 = 0,
};

fn snipHook(hook: *sdk.utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const seen: *Snipped = @ptrCast(@alignCast(hook.data.?));
    const msg: *const con.SnipHookMsg = @ptrCast(@alignCast(message.?));
    const from = msg.snip_data orelse return 0;
    const room = @min(msg.snip_len, seen.text.len);
    var i: u32 = 0;
    while (i < room) : (i += 1) {
        // A newline would break the one line this is printed on.
        seen.text[i] = if (from[i] == '\n' or from[i] == '\r') ' ' else from[i];
    }
    seen.text[room] = 0;
    seen.len = msg.snip_len;
    seen.fresh = 1;
    if (seen.sys) |sys| sys.Signal(seen.task.?, seen.signal);
    return 0;
}

/// A mouse report, `CSI < b ; col ; row M` or `m`, printed in the window
/// as words. How many bytes of `in` it took, or 0 when it is not one.
fn showMouse(in: []const u8, out: []u8) struct { usize, usize } {
    if (in.len < 6 or in[0] != 0x1B or in[1] != '[' or in[2] != '<') return .{ 0, 0 };
    var at: usize = 3;
    var value: [3]u32 = @splat(0);
    var which: usize = 0;
    while (at < in.len) : (at += 1) {
        const c = in[at];
        if (c >= '0' and c <= '9') {
            value[which] = value[which] * 10 + (c - '0');
        } else if (c == ';') {
            which += 1;
            if (which == 3) return .{ 0, 0 };
        } else if (c == 'M' or c == 'm') {
            const head = "  mouse ";
            var n: usize = 0;
            for (head) |h| {
                out[n] = h;
                n += 1;
            }
            const button = switch (value[0] & 3) {
                0 => "left ",
                1 => "middle ",
                2 => "right ",
                else => "none ",
            };
            for (button) |h| {
                out[n] = h;
                n += 1;
            }
            const what: []const u8 = if (value[0] & 32 != 0) "moved " else if (c == 'm') "up " else "down ";
            for (what) |h| {
                out[n] = h;
                n += 1;
            }
            out[n] = 'c';
            n += 1;
            n += digits(out[n..], value[1]);
            out[n] = ' ';
            n += 1;
            out[n] = 'r';
            n += 1;
            n += digits(out[n..], value[2]);
            out[n] = '\r';
            out[n + 1] = '\n';
            return .{ at + 1, n + 2 };
        } else return .{ 0, 0 };
    }
    return .{ 0, 0 };
}

fn attr(ib: *IntuitionBase, w: *intuition.Window, tag: sdk.utility.Tag) usize {
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

    var argv: [10]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const lib = sys.OpenLibrary(intuition.INTUITIONNAME, intuition.INTUITION_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{intuition.INTUITIONNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(lib);
    const ib: *IntuitionBase = @ptrCast(lib);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_WARN;
    };
    defer ib.UnlockPubScreen(null, screen);

    const title: [*:0]const u8 = if (argv[arg_title] != 0) @ptrFromInt(argv[arg_title]) else "Console";
    const tags = [_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Left, .data = 80 },
        .{ .tag = wn.WA_Top, .data = 60 },
        .{ .tag = wn.WA_Width, .data = 560 },
        .{ .tag = wn.WA_Height, .data = 320 },
        .{ .tag = wn.WA_MinWidth, .data = 200 },
        .{ .tag = wn.WA_MinHeight, .data = 100 },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(title) },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW },
        .{},
    };
    const window = ib.OpenWindowTagList(&tags) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    // SHELL hands the window to the console handler, which closes it.
    var handed_over = false;
    defer if (!handed_over) ib.CloseWindow(window);

    // A shell in this window: the console is opened by name, with the
    // window's address in the name, so what draws in it is CON: and not
    // this program. The window belongs to the console from then on - it
    // closes it when the shell closes its last handle, which is why this
    // does not close it itself.
    if (argv[arg_shell] != 0) {
        handed_over = true;
        var name: [48]u8 = @splat(0);
        _ = consoleName(&name, @intFromPtr(window));
        _ = Printf(dl, MSG_SHELL, .{@as([*:0]const u8, @ptrCast(&name))});
        const shell_tags = [_]TagItem{
            .{ .tag = dos.SYS_Window, .data = @intFromPtr(&name) },
            .{ .tag = dos.SYS_UserShell, .data = 1 },
            .{},
        };
        const rc = dl.SystemTagList(null, &shell_tags);
        if (rc < 0) {
            _ = Printf(dl, MSG_NOSHELL, .{});
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            handed_over = false;
            return dos.RETURN_FAIL;
        }
        _ = Printf(dl, MSG_SHELL_DONE, .{rc});
        return dos.RETURN_OK;
    }

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{};
    io.req.message.reply_port = port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    io.data = window;
    if (sys.OpenDevice(con.CONSOLENAME, @bitCast(con.CONU_SNIPMAP), &io.req, 0) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{con.CONSOLENAME});
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&io.req);
    // The device's own base, for the functions that are not commands.
    const cd: *con.ConsoleBase = @ptrCast(io.req.device.?);

    write(sys, &io, demo);

    // A long stream, so that the window scrolls: what it costs is what the
    // scroll is drawn with.
    if (argv[arg_scroll] != 0) {
        var line: u32 = 1;
        while (line <= 120) : (line += 1) {
            var text: [40]u8 = undefined;
            const n = numbered(&text, line);
            write(sys, &io, text[0..n]);
        }
    }

    // The other screen: what is written there is written over nothing, and
    // leaving it puts back what was under it.
    if (argv[arg_alt] != 0) {
        write(sys, &io, "\x1b[?1049h\x1b[H\x1b[7m The other screen \x1b[m\r\n\r\n" ++
            "  Nothing written here touches what was on the screen before.\r\n");
        _ = dl.Delay(250);
        write(sys, &io, "\x1b[?1049l");
    }

    // The size in characters, which the console asks the window for.
    if (argv[arg_rows] != 0 or argv[arg_cols] != 0) {
        const rows: u32 = if (argv[arg_rows] != 0) @intCast(@max(0, @as(*const i32, @ptrFromInt(argv[arg_rows])).*)) else 0;
        const cols: u32 = if (argv[arg_cols] != 0) @intCast(@max(0, @as(*const i32, @ptrFromInt(argv[arg_cols])).*)) else 0;
        var ask: [24]u8 = undefined;
        write(sys, &io, ask[0..sizeRequest(&ask, rows, cols)]);
    }

    // A write whose length is -1: the data runs to a NUL rather than for
    // a stated number of bytes.
    if (argv[arg_nul] != 0) {
        const text = "\r\n  A write of a NUL-terminated string, io_Length -1.\r\n";
        io.req.command = exec.CMD_WRITE;
        io.data = @constCast(@as([*]const u8, text.ptr));
        io.length = ~@as(u64, 0);
        _ = sys.DoIO(&io.req);
        // It answers with what it wrote, nothing left, and where it got to.
        _ = Printf(dl, "Console    wrote %ld of %ld bytes, %ld left\n", .{ io.actual, @as(u64, text.len), io.length });
    }

    // The pointer to the program rather than to the selection: moves with
    // a button down, in the form that says which button was let go.
    if (argv[arg_mouse] != 0) {
        write(sys, &io, "\r\n  Mouse reporting on. Press and drag in the window;\r\n" ++
            "  hold Shift to select text instead.\r\n");
        write(sys, &io, "\x1b[?1002h\x1b[?1006h");
    }

    // Told when a selection is finished, which is how a clipboard program
    // would take the text away.
    var seen = Snipped{};
    var hook = sdk.utility.Hook{ .entry = &snipHook, .data = &seen };
    var snip_bit: i8 = -1;
    if (argv[arg_snip] != 0) {
        snip_bit = sys.AllocSignal(-1);
        if (snip_bit < 0) return dos.RETURN_FAIL;
        seen.sys = sys;
        seen.task = sys.FindTask(null);
        seen.signal = @as(u32, 1) << @intCast(snip_bit);
        cd.AddSnipHook(&hook);
        write(sys, &io, "\r\n  A snip hook is installed: select text and it is reported.\r\n");
    }
    defer if (argv[arg_snip] != 0) {
        cd.RemSnipHook(&hook);
        sys.FreeSignal(snip_bit);
    };

    _ = Printf(dl, MSG_OPEN, .{});

    // A read of its own, so the window's messages and the keys are waited
    // for together.
    var reader: exec.IOStdReq = io;
    const read_port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(read_port);
    reader.req.message.reply_port = read_port;
    var typed: [64]u8 = undefined;
    var shown: [64]u8 = undefined;

    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    const window_port: *exec.MsgPort = @ptrFromInt(attr(ib, window, wn.WA_UserPort));
    var total: u32 = 0;
    var running = true;
    reader.req.command = exec.CMD_READ;
    reader.data = &typed;
    reader.length = typed.len;
    sys.SendIO(&reader.req);

    // Stopped, the unit queues its reads whatever is typed; started, it
    // answers them with everything that waited in the meantime.
    if (argv[arg_stop] != 0) {
        var stopper: exec.IOStdReq = io;
        stopper.req.command = exec.CMD_STOP;
        _ = sys.DoIO(&stopper.req);
        write(sys, &io, "\r\n  Stopped for three seconds - type, and nothing appears.\r\n");
        _ = Printf(dl, MSG_STOPPED, .{});
        _ = dl.Delay(150);
        stopper.req.command = exec.CMD_START;
        _ = sys.DoIO(&stopper.req);
        write(sys, &io, "  Started; what was typed arrives now.\r\n");
        _ = Printf(dl, MSG_STARTED, .{});
    }

    while (running) {
        const got = sys.Wait(read_port.sigMask() | window_port.sigMask() | seen.signal | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0) running = false;
        while (sys.GetMsg(window_port)) |m| {
            const im: *intuition.IntuiMessage = @ptrCast(@alignCast(m));
            if (im.class == wn.IDCMP_CLOSEWINDOW) running = false;
            sys.ReplyMsg(m);
        }
        // What the snip hook was handed, printed from here: the hook
        // itself runs on the console's task and may not wait.
        if (seen.fresh != 0) {
            seen.fresh = 0;
            _ = Printf(dl, MSG_SNIPPED, .{ @as(u64, seen.len), @as([*:0]const u8, &seen.text) });
        }
        if (sys.CheckIO(&reader.req) != null) {
            _ = sys.WaitIO(&reader.req);
            const n: usize = @intCast(reader.actual);
            if (n > 0) {
                total += @intCast(n);
                // A mouse report is written out as words rather than
                // echoed, which would put the sequence back on the screen.
                var at: usize = 0;
                while (at < n) {
                    const took, const said = showMouse(typed[at..n], &shown);
                    if (took == 0) {
                        write(sys, &io, typed[at .. at + 1]);
                        at += 1;
                    } else {
                        write(sys, &io, shown[0..said]);
                        at += took;
                    }
                }
            }
            if (running) {
                reader.req.command = exec.CMD_READ;
                reader.data = &typed;
                reader.length = typed.len;
                sys.SendIO(&reader.req);
            }
        }
    }
    if (sys.CheckIO(&reader.req) == null) _ = sys.AbortIO(&reader.req);
    _ = sys.WaitIO(&reader.req);
    _ = Printf(dl, MSG_DONE, .{total});
    return dos.RETURN_OK;
}
