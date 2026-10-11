// SPDX-License-Identifier: MIT
//! KeySource: keys and a mouse handed to keyboard.device and mouse.device
//! as a source does it - a keyboard's or a mouse's driver - with nothing
//! plugged in. Built against the SDK only.
//!
//!   KeySource TEXT,RETURN/S,MOUSE/S,X/K/N,Y/K/N,DX/K/N,DY/K/N,CLICK/S,WHEEL/K/N
//!
//! TEXT is typed: the device is opened with KBDF_SOURCE and each character
//! goes in with KBD_ADDEVENT as the key at its place on a US keyboard,
//! pressed and let go, Shift held around a capital or a shifted sign;
//! RETURN presses Return after it. What appears is the active keymap's
//! reading of those places, as with any keyboard. MOUSE opens mouse.device
//! with MOUSEF_SOURCE: X and Y put the pointer there, DX and DY move it by
//! that much (a distance, IEQUALIFIER_RELATIVEMOUSE), CLICK presses the
//! left button and lets it go, WHEEL turns the wheel by that many notches
//! down (up negative). The source is closed at the end, which lets go of
//! anything still held.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const kb = sdk.devices.keyboard;
const mouse = sdk.devices.mouse;
const ie = sdk.devices.inputevent;
const InputEvent = ie.InputEvent;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "KeySource";
const VERSION_STRING = "\x00$VER: KeySource 1.0 (11.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TEXT,RETURN/S,MOUSE/S,X/K/N,Y/K/N,DX/K/N,DY/K/N,CLICK/S,WHEEL/K/N";
const arg_text = 0;
const arg_return = 1;
const arg_mouse = 2;
const arg_x = 3;
const arg_y = 4;
const arg_dx = 5;
const arg_dy = 6;
const arg_click = 7;
const arg_wheel = 8;
const arg_count = 9;

const MSG_NODEVICE = "%s: cannot open %s as a source\n";
const MSG_SKIPPED = "%s: no key for '%c', left out\n";
const MSG_TYPED = "Typed %d keys\n";
const MSG_MOUSED = "Sent %d mouse events\n";
const MSG_FAILED = "%s: the device answered error %d\n";

/// A character's key: its rawkey, and whether Shift is held for it.
const Key = struct { code: u8, shift: bool };

/// The rawkeys of the US layout's rows, unshifted and shifted, at the
/// places keyboard.device's rawkeys name.
const rows = [_]struct { first: u8, plain: []const u8, shifted: []const u8 }{
    .{ .first = 0x00, .plain = "`1234567890-=\\", .shifted = "~!@#$%^&*()_+|" },
    .{ .first = 0x10, .plain = "qwertyuiop[]", .shifted = "QWERTYUIOP{}" },
    .{ .first = 0x20, .plain = "asdfghjkl;'", .shifted = "ASDFGHJKL:\"" },
    .{ .first = 0x31, .plain = "zxcvbnm,./", .shifted = "ZXCVBNM<>?" },
};

fn keyOf(c: u8) ?Key {
    if (c == ' ') return .{ .code = @intCast(kb.RAWKEY_SPACE), .shift = false };
    for (rows) |row| {
        for (row.plain, 0..) |p, i| {
            if (p == c) return .{ .code = row.first + @as(u8, @intCast(i)), .shift = false };
        }
        for (row.shifted, 0..) |p, i| {
            if (p == c) return .{ .code = row.first + @as(u8, @intCast(i)), .shift = true };
        }
    }
    return null;
}

fn rawkey(code: u32, down: bool) InputEvent {
    return .{ .class = ie.IECLASS_RAWKEY, .code = code | (if (down) 0 else ie.IECODE_UP_PREFIX) };
}

/// `events` handed to the device on `io`: the device's error, 0 if none.
fn send(sys: *ExecBase, io: *exec.IOStdReq, command: u16, events: []InputEvent) i32 {
    io.req.command = command;
    io.data = events.ptr;
    io.length = @intCast(events.len * @sizeOf(InputEvent));
    return sys.DoIO(&io.req);
}

fn typeText(sys: *ExecBase, dl: *DosBase, text: ?[*:0]const u8, press_return: bool) i32 {
    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{};
    io.req.message.reply_port = port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(kb.KEYBOARDNAME, 0, &io.req, kb.KBDF_SOURCE) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{ COMMAND_NAME, kb.KEYBOARDNAME });
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&io.req);
    var typed: u32 = 0;
    if (text) |t| {
        var at = t;
        while (at[0] != 0) : (at += 1) {
            const key = keyOf(at[0]) orelse {
                _ = Printf(dl, MSG_SKIPPED, .{ COMMAND_NAME, @as(u32, at[0]) });
                continue;
            };
            var events: [4]InputEvent = undefined;
            var n: usize = 0;
            if (key.shift) {
                events[n] = rawkey(kb.RAWKEY_LSHIFT, true);
                n += 1;
            }
            events[n] = rawkey(key.code, true);
            events[n + 1] = rawkey(key.code, false);
            n += 2;
            if (key.shift) {
                events[n] = rawkey(kb.RAWKEY_LSHIFT, false);
                n += 1;
            }
            const err = send(sys, &io, kb.KBD_ADDEVENT, events[0..n]);
            if (err != 0) {
                _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, @as(i32, err) });
                return dos.RETURN_FAIL;
            }
            typed += 1;
        }
    }
    if (press_return) {
        var events = [_]InputEvent{ rawkey(kb.RAWKEY_RETURN, true), rawkey(kb.RAWKEY_RETURN, false) };
        if (send(sys, &io, kb.KBD_ADDEVENT, &events) == 0) typed += 1;
    }
    _ = Printf(dl, MSG_TYPED, .{typed});
    return dos.RETURN_OK;
}

fn number(argv: []const usize, which: usize) ?i32 {
    if (argv[which] == 0) return null;
    return @as(*const i32, @ptrFromInt(argv[which])).*;
}

fn useMouse(sys: *ExecBase, dl: *DosBase, argv: []const usize) i32 {
    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{};
    io.req.message.reply_port = port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(mouse.MOUSENAME, 0, &io.req, mouse.MOUSEF_SOURCE) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{ COMMAND_NAME, mouse.MOUSENAME });
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(&io.req);

    var events: [5]InputEvent = undefined;
    var n: usize = 0;
    const x = number(argv, arg_x);
    const y = number(argv, arg_y);
    const dx = number(argv, arg_dx) orelse 0;
    const dy = number(argv, arg_dy) orelse 0;
    // A click is where the pointer was put, or by distance where it is.
    var click_at = InputEvent{ .class = ie.IECLASS_RAWMOUSE, .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE };
    if (x != null or y != null) {
        var state: mouse.MouseState = .{};
        io.req.command = mouse.MOUSE_READSTATE;
        io.data = &state;
        io.length = @sizeOf(mouse.MouseState);
        _ = sys.DoIO(&io.req);
        click_at = .{ .class = ie.IECLASS_RAWMOUSE, .x = x orelse state.x, .y = y orelse state.y };
        events[n] = click_at;
        events[n].code = ie.IECODE_NOBUTTON;
        n += 1;
    }
    if (dx != 0 or dy != 0) {
        events[n] = .{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_NOBUTTON, .qualifier = ie.IEQUALIFIER_RELATIVEMOUSE, .x = dx, .y = dy };
        n += 1;
    }
    if (argv[arg_click] != 0) {
        events[n] = click_at;
        events[n].code = ie.IECODE_LBUTTON;
        events[n + 1] = click_at;
        events[n + 1].code = ie.IECODE_LBUTTON | ie.IECODE_UP_PREFIX;
        n += 2;
    }
    if (number(argv, arg_wheel)) |notches| {
        events[n] = .{ .class = ie.IECLASS_RAWMOUSE, .code = ie.IECODE_WHEEL, .y = notches };
        n += 1;
    }
    if (n > 0) {
        const err = send(sys, &io, mouse.MOUSE_ADDEVENT, events[0..n]);
        if (err != 0) {
            _ = Printf(dl, MSG_FAILED, .{ COMMAND_NAME, @as(i32, err) });
            return dos.RETURN_FAIL;
        }
    }
    _ = Printf(dl, MSG_MOUSED, .{@as(u32, @intCast(n))});
    return dos.RETURN_OK;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    if (argv[arg_mouse] != 0) return useMouse(sys, dl, &argv);
    const text: ?[*:0]const u8 = if (argv[arg_text] != 0) @ptrFromInt(argv[arg_text]) else null;
    return typeText(sys, dl, text, argv[arg_return] != 0);
}
