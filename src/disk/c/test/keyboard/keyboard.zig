// SPDX-License-Identifier: MIT
//! Keyboard: the keys as keyboard.device hands them out. Built against the
//! SDK only.
//!
//!   Keyboard MATRIX/S
//!
//! With nothing asked for it prints every key as it goes down and up - its
//! rawkey, a name where the key has one, and the qualifiers held after it -
//! until Ctrl-C. MATRIX prints which keys are down now and stops.
//!
//! A read waits in the device until a key comes, so the command waits for
//! either the read or Ctrl-C, and takes the read back with AbortIO when it
//! is the Ctrl-C.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const kb = sdk.devices.keyboard;
const ie = sdk.devices.inputevent;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Keyboard";
const VERSION_STRING = "\x00$VER: Keyboard 1.0 (19.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "MATRIX/S";
const arg_matrix = 0;

const MSG_NODEVICE = "No %s - there is no keyboard\n";
const MSG_WAITING = "Type - Ctrl-C to stop\n";
const MSG_EVENT = "%02x %-10s %-4s%s at %d.%06d\n";
const MSG_DOWN = "Down      ";
const MSG_KEY = " %02x %s";
const MSG_NONE = " none";
const MSG_DONE = "%d events\n";
const MSG_FAILED = "The read failed: error %d\n";

/// A name for each rawkey that has an obvious one.
const names: [128][*:0]const u8 = blk: {
    var t: [128][*:0]const u8 = @splat("");
    const rows = [_]struct { at: u8, keys: []const u8 }{
        .{ .at = 0x01, .keys = "1234567890-=\\" },
        .{ .at = 0x10, .keys = "QWERTYUIOP[]" },
        .{ .at = 0x20, .keys = "ASDFGHJKL;'" },
        .{ .at = 0x31, .keys = "ZXCVBNM,./" },
    };
    for (rows) |r| {
        for (r.keys, 0..) |c, i| t[r.at + i] = &[_:0]u8{c};
    }
    t[0x00] = "`";
    t[0x0F] = "KP0";
    t[0x1D] = "KP1";
    t[0x1E] = "KP2";
    t[0x1F] = "KP3";
    t[0x2D] = "KP4";
    t[0x2E] = "KP5";
    t[0x2F] = "KP6";
    t[0x3D] = "KP7";
    t[0x3E] = "KP8";
    t[0x3F] = "KP9";
    t[0x3C] = "KP.";
    t[0x4A] = "KP-";
    t[0x5C] = "KP/";
    t[0x5D] = "KP*";
    t[0x5E] = "KP+";
    t[0x30] = "<>";
    t[kb.RAWKEY_SPACE] = "Space";
    t[kb.RAWKEY_BACKSPACE] = "Backspace";
    t[kb.RAWKEY_TAB] = "Tab";
    t[kb.RAWKEY_KP_ENTER] = "Enter";
    t[kb.RAWKEY_RETURN] = "Return";
    t[kb.RAWKEY_ESC] = "Esc";
    t[kb.RAWKEY_DEL] = "Del";
    t[kb.RAWKEY_INSERT] = "Insert";
    t[kb.RAWKEY_PAGEUP] = "PageUp";
    t[kb.RAWKEY_PAGEDOWN] = "PageDown";
    t[kb.RAWKEY_UP] = "Up";
    t[kb.RAWKEY_DOWN] = "Down";
    t[kb.RAWKEY_RIGHT] = "Right";
    t[kb.RAWKEY_LEFT] = "Left";
    for (0..10) |i| t[kb.RAWKEY_F1 + i] = "F" ++ [_:0]u8{'0' + (i + 1) % 10};
    t[kb.RAWKEY_F10] = "F10";
    t[kb.RAWKEY_F11] = "F11";
    t[kb.RAWKEY_F12] = "F12";
    t[kb.RAWKEY_HELP] = "Help";
    t[kb.RAWKEY_LSHIFT] = "LShift";
    t[kb.RAWKEY_RSHIFT] = "RShift";
    t[kb.RAWKEY_CAPSLOCK] = "CapsLock";
    t[kb.RAWKEY_CONTROL] = "Ctrl";
    t[kb.RAWKEY_LALT] = "LAlt";
    t[kb.RAWKEY_RALT] = "RAlt";
    t[kb.RAWKEY_LAMIGA] = "LAmiga";
    t[kb.RAWKEY_RAMIGA] = "RAmiga";
    t[kb.RAWKEY_HOME] = "Home";
    t[kb.RAWKEY_END] = "End";
    break :blk t;
};

const qualifier_names = [_]struct { bit: u32, name: [*:0]const u8 }{
    .{ .bit = ie.IEQUALIFIER_LSHIFT, .name = " lshift" },
    .{ .bit = ie.IEQUALIFIER_RSHIFT, .name = " rshift" },
    .{ .bit = ie.IEQUALIFIER_CAPSLOCK, .name = " caps" },
    .{ .bit = ie.IEQUALIFIER_CONTROL, .name = " ctrl" },
    .{ .bit = ie.IEQUALIFIER_LALT, .name = " lalt" },
    .{ .bit = ie.IEQUALIFIER_RALT, .name = " ralt" },
    .{ .bit = ie.IEQUALIFIER_LCOMMAND, .name = " lamiga" },
    .{ .bit = ie.IEQUALIFIER_RCOMMAND, .name = " ramiga" },
    .{ .bit = ie.IEQUALIFIER_NUMERICPAD, .name = " keypad" },
    .{ .bit = ie.IEQUALIFIER_REPEAT, .name = " repeat" },
};

/// The qualifiers by name, into `buf`.
fn qualifierText(q: u32, buf: *[96]u8) [*:0]const u8 {
    var n: usize = 0;
    for (qualifier_names) |qn| {
        if (q & qn.bit == 0) continue;
        var s = qn.name;
        while (s[0] != 0 and n < buf.len - 1) : (s += 1) {
            buf[n] = s[0];
            n += 1;
        }
    }
    buf[n] = 0;
    return @ptrCast(buf);
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

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{};
    io.req.message.reply_port = port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(kb.KEYBOARDNAME, 0, &io.req, 0) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{kb.KEYBOARDNAME});
        return dos.RETURN_WARN;
    }
    defer sys.CloseDevice(&io.req);

    if (argv[arg_matrix] != 0) {
        var matrix: [kb.MATRIX_BYTES]u8 = @splat(0);
        io.req.command = kb.KBD_READMATRIX;
        io.data = &matrix;
        io.length = matrix.len;
        _ = sys.DoIO(&io.req);
        _ = Printf(dl, MSG_DOWN, .{});
        var any = false;
        for (0..kb.HIGH_KEYCODE + 1) |r| {
            if (matrix[r / 8] & (@as(u8, 1) << @intCast(r % 8)) == 0) continue;
            _ = Printf(dl, MSG_KEY, .{ @as(u32, @intCast(r)), names[r] });
            any = true;
        }
        if (!any) _ = Printf(dl, MSG_NONE, .{});
        _ = Printf(dl, "\n", .{});
        return dos.RETURN_OK;
    }

    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    _ = Printf(dl, MSG_WAITING, .{});
    var events: [8]ie.InputEvent = undefined;
    var total: u32 = 0;
    var qbuf: [96]u8 = undefined;
    while (true) {
        io.req.command = kb.KBD_READEVENT;
        io.data = &events;
        io.length = @sizeOf(@TypeOf(events));
        sys.SendIO(&io.req);
        const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0 and sys.CheckIO(&io.req) == null) {
            _ = sys.AbortIO(&io.req);
            _ = sys.WaitIO(&io.req);
            break;
        }
        _ = sys.WaitIO(&io.req);
        if (io.req.err != 0) {
            _ = Printf(dl, MSG_FAILED, .{@as(i32, io.req.err)});
            break;
        }
        var at: ?*ie.InputEvent = if (io.actual > 0) &events[0] else null;
        while (at) |e| : (at = e.next) {
            const code = e.code & ie.IECODE_KEY_CODE_MASK;
            const up = e.code & ie.IECODE_UP_PREFIX != 0;
            const dir: [*:0]const u8 = if (up) "up" else "down";
            _ = Printf(dl, MSG_EVENT, .{ code, names[code], dir, qualifierText(e.qualifier, &qbuf), e.time.secs, e.time.micro });
            total += 1;
        }
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
    }
    _ = Printf(dl, MSG_DONE, .{total});
    return dos.RETURN_OK;
}
