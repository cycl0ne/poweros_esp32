// SPDX-License-Identifier: MIT
//! Terminal: a window joined to a serial line - what comes in is shown,
//! what is typed goes out. Built against the SDK only.
//!
//!   Terminal DEVICE,UNIT/K/N,BAUD/K/N,FRAME/K,SETTINGS/S
//!
//! The window is console.device's (`CONU_SNIPMAP`): VT100 with what of
//! xterm a program expects - colours, the line-drawing set, the second
//! screen, the cursor keys, the answers to a terminal's questions - text
//! selected with the pointer and pasted back with right-Amiga-V or
//! Shift-Insert, the text kept and laid out again when the window is
//! sized. Terminal itself only carries the bytes: the line's to the
//! console, the console's - keys, pastes, its answers - to the line.
//!
//! The line and how it runs are the settings (settings.zig): read from
//! `ENV:Terminal.prefs`, then changed by the arguments - DEVICE and UNIT
//! the line, BAUD its speed, FRAME `8N1` and the like. With no line, or
//! with SETTINGS, the settings window opens at the start (setup.zig):
//! its Line field lists the serial lines this board has, by
//! asl.library's device requester.
//!
//! The menus, with their right-Amiga keys:
//!
//!   Project  Settings... (S), Send File... (U), Capture to File... (L),
//!            End Capture, About, Quit (Q)
//!   Line     Send Break (B), Clear Screen (K), Reset Terminal
//!
//! Send File sends a file's bytes as they are; a file dropped on the
//! window from the desktop is sent the same way. Capture to File keeps
//! everything that comes in, as it came, until End Capture. The window's
//! title says which line it is on, how it runs, and whether it captures.
//! The close gadget, Quit or Ctrl-C end it.

const sdk = @import("sdk");
const asl = sdk.asl;
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const con = sdk.console;
const wn = intuition.windows;
const mn = intuition.menus;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const AslBase = sdk.interface.asl.AslBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const TagItem = sdk.utility.TagItem;
const Window = intuition.Window;
const Printf = dos.stdio.Printf;
const prefs = sdk.prefs;
const settings_file = @import("settings.zig");
const Settings = settings_file.Settings;
const Line = @import("line.zig").Line;
const Setup = @import("setup.zig").Setup;

pub const COMMAND_NAME = "Terminal";
const VERSION = "1.1";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (27.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
/// What the screen's bar says while one of its windows is active.
const SCREEN_TITLE = COMMAND_NAME ++ " " ++ VERSION;

const template = "DEVICE,UNIT/K/N,BAUD/K/N,FRAME/K,SETTINGS/S";
const arg_device = 0;
const arg_unit = 1;
const arg_baud = 2;
const arg_frame = 3;
const arg_settings = 4;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOSCREEN = "No default screen - no display\n";
const MSG_NOWINDOW = "No window\n";
const MSG_BADSETTINGS = "%s: %s: %s\n";

/// The longest path a file is kept by.
const path_size = 256;

// The menus and their items, in the order of `menus` below; a bar counts
// as an item.
const MENU_PROJECT = 0;
const MENU_LINE = 1;

const ITEM_SETTINGS = 0;
const ITEM_SEND = 2;
const ITEM_CAPTURE = 3;
const ITEM_END_CAPTURE = 4;
const ITEM_ABOUT = 6;
const ITEM_QUIT = 7;

const ITEM_BREAK = 0;
const ITEM_CLEAR = 1;
const ITEM_RESET = 2;

fn item(label: [*:0]const u8, key: ?[*:0]const u8) mn.NewMenu {
    return .{ .type = mn.NM_ITEM, .label = label, .comm_key = key };
}

const bar = mn.NewMenu{ .type = mn.NM_ITEM, .label = mn.NM_BARLABEL };

const menus = [_]mn.NewMenu{
    .{ .type = mn.NM_TITLE, .label = "Project" },
    item("Settings...", "S"),
    bar,
    item("Send File...", "U"),
    item("Capture to File...", "L"),
    item("End Capture", null),
    bar,
    item("About", null),
    item("Quit", "Q"),
    .{ .type = mn.NM_TITLE, .label = "Line" },
    item("Send Break", "B"),
    item("Clear Screen", "K"),
    item("Reset Terminal", null),
    .{},
};

/// What a VT100 starts with and the console does not: new-line mode off,
/// so Return is a carriage return alone and a line feed only goes down.
const vt100_modes = "\x1b[20l";

const Terminal = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ib: *IntuitionBase,
    screen: *intuition.Screen,
    window: *Window,
    strip: ?*mn.Menu = null,
    /// The console: one request for writing, one always out reading what
    /// is typed, each on a port of its own.
    con_port: *exec.MsgPort,
    con_write: exec.IOStdReq = .{},
    con_read: exec.IOStdReq = .{},
    read_port: *exec.MsgPort,
    typed: [128]u8 = @splat(0),
    line: Line,
    settings: Settings = .{},
    setup: Setup,
    /// The file what comes in is kept in, and its name.
    capture: ?*dos.FileHandle = null,
    capture_name: [path_size:0]u8 = @splat(0),
    /// The byte shown last, for a line feed that wants a carriage return
    /// before it.
    last_shown: u8 = 0,
    /// Why the line is not open, when it is not.
    trouble: ?[*:0]const u8 = null,
    title: [160:0]u8 = @splat(0),
    /// The window as one files can be dropped on, while the desktop runs.
    drop: sdk.anvil.DropTarget = .{},

    // --- the console --------------------------------------------------------

    fn show(term: *Terminal, bytes: []const u8) void {
        if (bytes.len == 0) return;
        term.con_write.req.command = exec.CMD_WRITE;
        term.con_write.data = @constCast(bytes.ptr);
        term.con_write.length = bytes.len;
        _ = term.sys.DoIO(&term.con_write.req);
    }

    fn startReading(term: *Terminal) void {
        term.con_read.req.command = exec.CMD_READ;
        term.con_read.data = &term.typed;
        term.con_read.length = term.typed.len;
        term.sys.SendIO(&term.con_read.req);
    }

    /// A note from Terminal itself in the window, on a line of its own,
    /// set off from what the line sends.
    fn note(term: *Terminal, text: []const u8) void {
        term.show("\r\n\x1b[7m ");
        term.show(text);
        term.show(" \x1b[m\r\n");
        term.last_shown = '\n';
    }

    // --- the line -----------------------------------------------------------

    /// The bytes the line sent, shown and kept.
    fn fromLine(term: *Terminal, bytes: []const u8) void {
        if (term.capture) |file| _ = term.dl.Write(file, bytes.ptr, @intCast(bytes.len));
        var shown: [2 * 512]u8 = undefined;
        var at: usize = 0;
        while (at < bytes.len) {
            const piece = bytes[at..@min(bytes.len, at + shown.len / 2)];
            const n = settings_file.shown(&term.settings, piece, &term.last_shown, &shown);
            term.show(shown[0..n]);
            at += piece.len;
        }
    }

    /// What was typed - or pasted, or the console's answer to a question
    /// the far end asked - sent on the line, Return as the settings say.
    fn fromKeys(term: *Terminal, bytes: []const u8) void {
        if (!term.line.open) {
            term.note("No line: Settings... (right-Amiga S) chooses one.");
            return;
        }
        var start: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (bytes[i] != '\r') continue;
            term.line.send(bytes[start..i]);
            term.line.send(settings_file.returnBytes(&term.settings));
            // In new-line mode, which the far end may set, the console
            // gives Return as CR LF: one Return all the same.
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
            start = i + 1;
        }
        term.line.send(bytes[start..]);
        if (term.settings.echo) {
            for (bytes) |byte| {
                if (byte == '\r') term.show("\r\n") else term.show(&[1]u8{byte});
            }
        }
    }

    /// The line the settings name opened, and the title saying so.
    fn openLine(term: *Terminal) void {
        term.trouble = term.line.openLine(&term.settings);
        if (term.trouble) |why| {
            var text: [120]u8 = undefined;
            var at: usize = 0;
            if (term.settings.deviceName()) |name| {
                at = putText(&text, at, name);
                at = putText(&text, at, " unit ");
                at = putNumber(&text, at, term.settings.unit);
            } else {
                at = putText(&text, at, "The line");
            }
            at = putText(&text, at, ": ");
            at = putText(&text, at, why);
            term.note(text[0..at]);
        }
        term.showTitle();
    }

    // --- the title ----------------------------------------------------------

    fn showTitle(term: *Terminal) void {
        var at: usize = 0;
        const t = &term.title;
        at = putText(t, at, "Terminal: ");
        if (term.line.open) {
            at = putText(t, at, term.settings.deviceName().?);
            at = putText(t, at, " ");
            at = putNumber(t, at, term.settings.unit);
            at = putText(t, at, ", ");
            at = putNumber(t, at, term.settings.baud);
            at = putText(t, at, " ");
            at = putText(t, at, term.settings.frameOf().name);
            if (term.settings.handshake == .xonxoff) at = putText(t, at, " xON/xOFF");
        } else {
            at = putText(t, at, "no line");
        }
        if (term.capture != null) {
            at = putText(t, at, " - capturing to ");
            at = putText(t, at, &term.capture_name);
        }
        t[@min(at, t.len)] = 0;
        term.ib.SetWindowTitles(term.window, t, SCREEN_TITLE);
    }

    // --- settings -----------------------------------------------------------

    fn openSetup(term: *Terminal) void {
        if (!term.setup.open(term.screen, &term.settings)) term.note("The settings window could not be opened.");
    }

    /// The settings window acted on; new settings taken.
    fn setupWindow(term: *Terminal) void {
        var new = term.settings;
        const outcome = term.setup.handle(&new);
        switch (outcome) {
            .open, .cancel => return,
            .save, .use => {},
        }
        const same_line = term.line.open and new.sameLine(&term.settings);
        term.settings = new;
        if (same_line) {
            if (!term.line.change(&term.settings)) term.note("The line does not take these settings.");
            term.showTitle();
        } else {
            term.openLine();
        }
        var text: [160]u8 = undefined;
        const n = settings_file.write(&term.settings, &text);
        _ = prefs.save(term.dl, settings_file.ENV_FILE, text[0..n]);
        if (outcome == .save) _ = prefs.save(term.dl, settings_file.ENVARC_FILE, text[0..n]);
        term.ib.ActivateWindow(term.window);
    }

    // --- files --------------------------------------------------------------

    /// A file's name asked for with asl.library's requester, into `into`.
    fn askFile(term: *Terminal, title: [*:0]const u8, save: bool, into: *[path_size:0]u8) bool {
        const lib = term.sys.OpenLibrary(asl.ASLNAME, 0) orelse return false;
        defer term.sys.CloseLibrary(lib);
        const ab: *AslBase = @ptrCast(lib);
        const request = ab.AllocAslRequest(asl.ASL_FileRequest, &[_]TagItem{
            .{ .tag = asl.ASLFR_Window, .data = @intFromPtr(term.window) },
            .{ .tag = asl.ASLFR_TitleText, .data = @intFromPtr(title) },
            .{ .tag = asl.ASLFR_DoSaveMode, .data = @intFromBool(save) },
            .{ .tag = asl.ASLFR_InitialDrawer, .data = @intFromPtr("RAM:") },
            .{},
        }) orelse return false;
        defer ab.FreeAslRequest(request);
        if (!ab.AslRequest(request, null)) return false;
        const answer: *asl.FileRequester = @ptrCast(@alignCast(request));
        into.* = @splat(0);
        var at: usize = 0;
        const drawer: [*:0]const u8 = answer.drawer orelse "";
        while (drawer[at] != 0 and at < path_size - 1) : (at += 1) into[at] = drawer[at];
        return term.dl.AddPart(into, answer.file orelse "", path_size);
    }

    /// A file's bytes sent on the line, as they are.
    fn sendFile(term: *Terminal, name: [*:0]const u8) void {
        if (!term.line.open) {
            term.note("No line to send it on.");
            return;
        }
        const file = term.dl.Open(name, dos.MODE_OLDFILE) orelse {
            term.note("That file cannot be opened.");
            return;
        };
        defer _ = term.dl.Close(file);
        var chunk: [512]u8 = undefined;
        var sent: u32 = 0;
        while (true) {
            const got = term.dl.Read(file, &chunk, chunk.len);
            if (got <= 0) break;
            const n: usize = @intCast(got);
            term.line.send(chunk[0..n]);
            sent += @intCast(n);
            // What comes back meanwhile is shown as it comes.
            term.fromLine(term.line.received());
        }
        var text: [48]u8 = undefined;
        var at = putText(&text, 0, "Sent ");
        at = putNumber(&text, at, sent);
        at = putText(&text, at, " bytes.");
        term.note(text[0..at]);
    }

    fn startCapture(term: *Terminal) void {
        var name: [path_size:0]u8 = undefined;
        if (!term.askFile("Capture to file", true, &name)) return;
        term.endCapture();
        term.capture = term.dl.Open(&name, dos.MODE_NEWFILE) orelse {
            term.note("That file cannot be written.");
            return;
        };
        term.capture_name = name;
        term.showTitle();
    }

    fn endCapture(term: *Terminal) void {
        const file = term.capture orelse return;
        _ = term.dl.Close(file);
        term.capture = null;
        term.showTitle();
    }

    // --- the menus ----------------------------------------------------------

    /// A menu item picked. False to end.
    fn picked(term: *Terminal, number: u32) bool {
        switch (mn.MENUNUM(number)) {
            MENU_PROJECT => switch (mn.ITEMNUM(number)) {
                ITEM_SETTINGS => term.openSetup(),
                ITEM_SEND => {
                    var name: [path_size:0]u8 = undefined;
                    if (term.askFile("Send a file", false, &name)) term.sendFile(&name);
                },
                ITEM_CAPTURE => term.startCapture(),
                ITEM_END_CAPTURE => term.endCapture(),
                ITEM_ABOUT => term.note(VERSION_STRING[7 .. VERSION_STRING.len - 2] ++ " - a terminal on a serial line"),
                ITEM_QUIT => return false,
                else => {},
            },
            MENU_LINE => switch (mn.ITEMNUM(number)) {
                ITEM_BREAK => term.line.sendBreak(),
                ITEM_CLEAR => term.show("\x1b[H\x1b[2J"),
                ITEM_RESET => term.show("\x1bc" ++ vt100_modes),
                else => {},
            },
            else => {},
        }
        return true;
    }

    /// The window's messages. False to end.
    fn windowMessages(term: *Terminal) bool {
        var going = true;
        while (term.ib.GetIMsg(term.window)) |im| {
            const class = im.class;
            const code = im.code;
            term.ib.ReplyIMsg(im);
            switch (class) {
                wn.IDCMP_CLOSEWINDOW => going = false,
                wn.IDCMP_MENUPICK => {
                    var number = code;
                    while (going and number != mn.MENUNULL) {
                        const next = if (term.ib.ItemAddress(term.strip, number)) |picked_item| picked_item.next_select else mn.MENUNULL;
                        if (!term.picked(number)) going = false;
                        number = next;
                    }
                },
                else => {},
            }
        }
        return going;
    }

    /// Files let go on the window: each sent, as Send File sends one.
    fn dropped(term: *Terminal) void {
        var name: [path_size:0]u8 = undefined;
        while (term.drop.next(term.dl, &name)) |file| {
            if (file.is_drawer) continue;
            term.sendFile(file.name);
        }
    }

    fn run(term: *Terminal) void {
        term.startReading();
        defer {
            if (term.sys.CheckIO(&term.con_read.req) == null) _ = term.sys.AbortIO(&term.con_read.req);
            _ = term.sys.WaitIO(&term.con_read.req);
        }
        var window_signal: u32 = 0;
        var window_port: usize = 0;
        const ask_port = [_]TagItem{ .{ .tag = wn.WA_UserPort, .data = @intFromPtr(&window_port) }, .{} };
        term.ib.GetWindowAttrs(term.window, &ask_port);
        if (window_port != 0) window_signal = @as(*exec.MsgPort, @ptrFromInt(window_port)).sigMask();
        while (true) {
            const keys_signal = term.read_port.sigMask();
            const wanted = window_signal | keys_signal | term.line.signal() | term.setup.signal() |
                term.drop.signal() | exec.SIGBREAKF_CTRL_C;
            const got = term.sys.Wait(wanted);
            if (got & exec.SIGBREAKF_CTRL_C != 0) return;
            term.fromLine(term.line.received());
            if (term.sys.CheckIO(&term.con_read.req) != null) {
                _ = term.sys.WaitIO(&term.con_read.req);
                const n: usize = @intCast(term.con_read.actual);
                term.fromKeys(term.typed[0..n]);
                term.startReading();
            }
            if (term.setup.isOpen() and got & term.setup.signal() != 0) term.setupWindow();
            if (got & term.drop.signal() != 0) term.dropped();
            if (!term.windowMessages()) return;
        }
    }
};

/// Text put into `into` from `at`, as far as it fits with a NUL after it;
/// where it ends.
fn putText(into: []u8, at: usize, text: anytype) usize {
    const bytes: []const u8 = switch (@typeInfo(@TypeOf(text))) {
        .pointer => |p| if (p.size == .many) blk: {
            var len: usize = 0;
            while (text[len] != 0) len += 1;
            break :blk text[0..len];
        } else text,
        else => text,
    };
    var put = at;
    for (bytes) |byte| {
        if (byte == 0 or put + 1 >= into.len) break;
        into[put] = byte;
        put += 1;
    }
    return put;
}

fn putNumber(into: []u8, at: usize, value: u32) usize {
    var digits: [10]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    var put = at;
    while (count > 0 and put + 1 < into.len) : (put += 1) {
        count -= 1;
        into[put] = digits[count];
    }
    return put;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [5]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const util_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(util_lib);
    const ub: *UtilityBase = @ptrCast(util_lib);

    // The settings: the saved ones, then what the arguments change.
    var settings: Settings = .{};
    var saved: [512]u8 = undefined;
    if (prefs.load(dl, settings_file.ENV_FILE, &saved)) |text| {
        if (settings_file.parse(ub, text, &settings)) |why| {
            _ = Printf(dl, MSG_BADSETTINGS, .{ COMMAND_NAME, @as([*:0]const u8, settings_file.ENV_FILE), why });
        }
    }
    if (dos.rdargs.string(argv[arg_device])) |name| {
        var n: usize = 0;
        while (name[n] != 0) n += 1;
        _ = settings.setDevice(name[0..n]);
        settings.unit = 0;
    }
    if (dos.rdargs.number(argv[arg_unit])) |unit| settings.unit = @bitCast(unit);
    if (dos.rdargs.number(argv[arg_baud])) |baud| if (baud > 0) {
        settings.baud = @intCast(baud);
    };
    if (dos.rdargs.string(argv[arg_frame])) |frame| {
        var words: [24]u8 = undefined;
        const head = "FRAME=";
        @memcpy(words[0..head.len], head);
        var n: usize = 0;
        while (frame[n] != 0 and head.len + n < words.len) : (n += 1) words[head.len + n] = frame[n];
        if (settings_file.parse(ub, words[0 .. head.len + n], &settings)) |why| {
            _ = Printf(dl, "%s: %s\n", .{ COMMAND_NAME, why });
            return dos.RETURN_ERROR;
        }
    }

    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, intuition.INTUITIONNAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);

    const screen = ib.LockPubScreen(null) orelse {
        _ = Printf(dl, MSG_NOSCREEN, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.UnlockPubScreen(null, screen);

    const window = ib.OpenWindowTagList(&[_]TagItem{
        .{ .tag = wn.WA_PubScreen, .data = @intFromPtr(screen) },
        .{ .tag = wn.WA_Title, .data = @intFromPtr(COMMAND_NAME) },
        .{ .tag = wn.WA_ScreenTitle, .data = @intFromPtr(SCREEN_TITLE) },
        .{ .tag = wn.WA_InnerWidth, .data = 660 },
        .{ .tag = wn.WA_InnerHeight, .data = 400 },
        .{ .tag = wn.WA_AutoAdjust, .data = 1 },
        .{ .tag = wn.WA_MinWidth, .data = 200 },
        .{ .tag = wn.WA_MinHeight, .data = 100 },
        // A terminal lays its text out in columns: the fixed font.
        .{ .tag = wn.WA_SysFont, .data = intuition.screens.SYSFONT_FIXED },
        .{ .tag = wn.WA_CloseGadget, .data = 1 },
        .{ .tag = wn.WA_DepthGadget, .data = 1 },
        .{ .tag = wn.WA_SizeGadget, .data = 1 },
        .{ .tag = wn.WA_DragBar, .data = 1 },
        .{ .tag = wn.WA_Activate, .data = 1 },
        .{ .tag = wn.WA_IDCMP, .data = wn.IDCMP_CLOSEWINDOW | wn.IDCMP_MENUPICK },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOWINDOW, .{});
        return dos.RETURN_FAIL;
    };
    defer ib.CloseWindow(window);

    // The menus; a terminal without them still carries the line, so a
    // strip that will not go on is left off rather than given up over.
    const strip = blk: {
        const made = ib.CreateMenusA(&menus, null) orelse break :blk null;
        if (!ib.LayoutMenusA(made, screen, null) or !ib.SetMenuStrip(window, made)) {
            ib.FreeMenus(made);
            break :blk null;
        }
        break :blk made;
    };
    defer if (strip) |made| {
        ib.ClearMenuStrip(window);
        ib.FreeMenus(made);
    };

    const con_port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(con_port);
    const read_port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(read_port);
    var term = Terminal{
        .sys = sys,
        .dl = dl,
        .ib = ib,
        .screen = screen,
        .window = window,
        .strip = strip,
        .con_port = con_port,
        .read_port = read_port,
        .line = .{ .sys = sys },
        .settings = settings,
        .setup = .{ .sys = sys, .ib = ib },
    };
    term.con_write.req.message.reply_port = con_port;
    term.con_write.req.message.length = @sizeOf(exec.IOStdReq);
    term.con_write.data = window;
    if (sys.OpenDevice(con.CONSOLENAME, @bitCast(con.CONU_SNIPMAP), &term.con_write.req, 0) != 0) {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, con.CONSOLENAME)});
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&term.con_write.req);
    term.con_read = term.con_write;
    term.con_read.req.message.reply_port = read_port;
    term.show(vt100_modes);

    // Taken off the desktop's list before the window closes.
    term.drop.add(sys, window);
    defer term.drop.remove();
    defer term.endCapture();
    defer term.setup.close();
    defer term.line.closeLine();

    if (term.settings.deviceName() != null) term.openLine() else term.showTitle();
    if (argv[arg_settings] != 0 or term.settings.deviceName() == null) term.openSetup();
    term.run();
    return dos.RETURN_OK;
}
